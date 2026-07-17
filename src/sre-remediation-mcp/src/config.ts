import { z } from 'zod';

const configSchema = z.object({
  PORT: z.coerce.number().int().min(1).max(65535).default(8080),
  ALLOWED_CALLER_PRINCIPAL_ID: z.string().uuid(),
  ENTRA_TENANT_ID: z.string().uuid(),
  ENTRA_TOKEN_AUDIENCE: z.string().regex(
    /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/
  ),
  GITHUB_APP_PRIVATE_KEY_KEY_URI: z
    .string()
    .url()
    .regex(/^https:\/\/[0-9A-Za-z-]+\.vault\.azure\.net\/keys\/[0-9A-Za-z-]{1,127}$/),
  GITHUB_APP_ID: z.string().regex(/^[1-9][0-9]*$/),
  GITHUB_APP_INSTALLATION_ID: z.string().regex(/^[1-9][0-9]*$/),
  GITHUB_APP_BOT_LOGIN: z
    .string()
    .regex(/^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})\[bot\]$/),
  GITHUB_REPOSITORY_OWNER: z.string().regex(/^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$/),
  GITHUB_REPOSITORY_NAME: z
    .string()
    .regex(/^[A-Za-z0-9._-]{1,100}$/)
});

export type BrokerConfig = {
  port: number;
  allowedCallerPrincipalId: string;
  entraTenantId: string;
  entraTokenAudience: string;
  privateKeyUri: string;
  githubAppId: string;
  githubAppInstallationId: string;
  githubAppBotLogin: string;
  repositoryOwner: string;
  repositoryName: string;
};

export function loadConfig(
  environment: NodeJS.ProcessEnv = process.env
): BrokerConfig {
  const parsed = configSchema.parse(environment);
  return {
    port: parsed.PORT,
    allowedCallerPrincipalId:
      parsed.ALLOWED_CALLER_PRINCIPAL_ID.toLowerCase(),
    entraTenantId: parsed.ENTRA_TENANT_ID.toLowerCase(),
    entraTokenAudience: parsed.ENTRA_TOKEN_AUDIENCE.toLowerCase(),
    privateKeyUri: parsed.GITHUB_APP_PRIVATE_KEY_KEY_URI,
    githubAppId: parsed.GITHUB_APP_ID,
    githubAppInstallationId: parsed.GITHUB_APP_INSTALLATION_ID,
    githubAppBotLogin: parsed.GITHUB_APP_BOT_LOGIN,
    repositoryOwner: parsed.GITHUB_REPOSITORY_OWNER,
    repositoryName: parsed.GITHUB_REPOSITORY_NAME
  };
}
