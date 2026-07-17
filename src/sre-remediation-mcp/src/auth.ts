import type { NextFunction, Request, Response } from 'express';
import {
  createRemoteJWKSet,
  errors,
  jwtVerify,
  type JWTPayload,
  type JWTVerifyGetKey
} from 'jose';
import { z } from 'zod';

const oidcConfigurationSchema = z.object({
  issuer: z.string().url(),
  jwks_uri: z.string().url()
});

const verifiedClaimsSchema = z.object({
  oid: z.string().uuid(),
  tid: z.string().uuid()
});

export class InvalidAccessTokenError extends Error {}
export class TokenVerificationUnavailableError extends Error {}

export interface VerifiedAccessToken {
  oid: string;
  tid: string;
}

export interface AccessTokenVerifier {
  verify(token: string): Promise<VerifiedAccessToken>;
}

export class EntraAccessTokenVerifier implements AccessTokenVerifier {
  private readonly issuer: string;

  constructor(
    private readonly tenantId: string,
    private readonly audience: string,
    private readonly signingKeyResolver: JWTVerifyGetKey,
    issuer = `https://login.microsoftonline.com/${tenantId}/v2.0`
  ) {
    this.issuer = issuer;
  }

  static async create(
    tenantId: string,
    audience: string,
    fetchImplementation: typeof fetch = fetch
  ): Promise<EntraAccessTokenVerifier> {
    const expectedIssuer = `https://login.microsoftonline.com/${tenantId}/v2.0`;
    const discoveryUrl = `${expectedIssuer}/.well-known/openid-configuration`;
    const response = await fetchImplementation(discoveryUrl, {
      headers: { Accept: 'application/json' },
      signal: AbortSignal.timeout(10_000)
    });
    if (!response.ok) {
      throw new Error(
        `Microsoft Entra OIDC discovery failed with status ${response.status}`
      );
    }

    const configuration = oidcConfigurationSchema.parse(await response.json());
    if (configuration.issuer !== expectedIssuer) {
      throw new Error(
        'Microsoft Entra OIDC discovery returned an unexpected issuer'
      );
    }
    const jwksUrl = new URL(configuration.jwks_uri);
    if (
      jwksUrl.protocol !== 'https:' ||
      jwksUrl.hostname !== 'login.microsoftonline.com'
    ) {
      throw new Error(
        'Microsoft Entra OIDC discovery returned an invalid JWKS URL'
      );
    }

    return new EntraAccessTokenVerifier(
      tenantId,
      audience,
      createRemoteJWKSet(jwksUrl, {
        timeoutDuration: 10_000,
        cooldownDuration: 30_000,
        cacheMaxAge: 10 * 60_000
      }),
      configuration.issuer
    );
  }

  async verify(token: string): Promise<VerifiedAccessToken> {
    let payload: JWTPayload;
    try {
      ({ payload } = await jwtVerify(token, this.signingKeyResolver, {
        algorithms: ['RS256'],
        issuer: this.issuer,
        audience: this.audience,
        clockTolerance: 30,
        requiredClaims: ['exp', 'iss', 'aud', 'oid', 'tid']
      }));
    } catch (error) {
      if (
        error instanceof errors.JWKSTimeout ||
        error instanceof TypeError
      ) {
        throw new TokenVerificationUnavailableError(
          'Microsoft Entra signing keys are temporarily unavailable'
        );
      }
      if (error instanceof errors.JOSEError) {
        throw new InvalidAccessTokenError(
          'Microsoft Entra access token is invalid'
        );
      }
      throw error;
    }

    const claims = verifiedClaimsSchema.safeParse(payload);
    if (
      !claims.success ||
      claims.data.tid.toLowerCase() !== this.tenantId.toLowerCase()
    ) {
      throw new InvalidAccessTokenError(
        'Microsoft Entra access token claims are invalid'
      );
    }

    return {
      oid: claims.data.oid.toLowerCase(),
      tid: claims.data.tid.toLowerCase()
    };
  }
}

export function authorizeCaller(
  expectedPrincipalId: string,
  verifier: AccessTokenVerifier
) {
  const expected = expectedPrincipalId.toLowerCase();

  return async (
    request: Request,
    response: Response,
    next: NextFunction
  ): Promise<void> => {
    const accessToken = request.header('x-ms-token-aad-access-token');
    const platformPrincipal = request
      .header('x-ms-client-principal-id')
      ?.toLowerCase();
    if (!accessToken || !platformPrincipal) {
      response.status(401).json({ error: 'Unauthorized' });
      return;
    }

    let claims: VerifiedAccessToken;
    try {
      claims = await verifier.verify(accessToken);
    } catch (error) {
      if (error instanceof TokenVerificationUnavailableError) {
        response.status(503).json({ error: 'Authentication service unavailable' });
        return;
      }
      if (error instanceof InvalidAccessTokenError) {
        response.status(401).json({ error: 'Unauthorized' });
        return;
      }
      next(error);
      return;
    }

    const principalId = claims.oid.toLowerCase();
    if (principalId !== expected || platformPrincipal !== principalId) {
      response.status(403).json({ error: 'Forbidden' });
      return;
    }

    next();
  };
}
