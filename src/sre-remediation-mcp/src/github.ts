import { createHash } from 'node:crypto';
import { DefaultAzureCredential } from '@azure/identity';
import {
  CryptographyClient,
  KeyClient,
  type KeyVaultKey
} from '@azure/keyvault-keys';
import type { TokenCredential } from '@azure/core-auth';
import { z } from 'zod';
import type { BrokerConfig } from './config.js';

const ISSUE_TITLE = '[SRE] Remediate ContosoPay slow memory leak';
const ISSUE_LABEL = 'sre-remediation';
const ISSUE_MARKER = '<!-- sre-remediation:payment-slow-leak -->';
const ISSUE_BODY = `${ISSUE_MARKER}

Azure SRE Agent detected the ContosoPay payment-service slow memory leak.

Create the narrowly scoped remediation pull request for human review. The
workflow must change only \`infra/leak.auto.tfvars\` from
\`enable_slow_leak = true\` to \`enable_slow_leak = false\`.`;

const installationTokenSchema = z.object({
  token: z.string().min(1),
  expires_at: z.string().datetime()
});

const issueSchema = z.object({
  number: z.number().int().positive(),
  html_url: z.string().url(),
  title: z.string(),
  body: z.string().nullable(),
  state: z.enum(['open', 'closed']),
  user: z.object({ login: z.string() }),
  labels: z.array(
    z.union([
      z.string(),
      z.object({ name: z.string().nullable() }).passthrough()
    ])
  )
});

const commentSchema = z.object({
  html_url: z.string().url(),
  body: z.string(),
  user: z.object({ login: z.string() })
});

const labelSchema = z.object({
  name: z.string(),
  color: z.string()
});

const issueListSchema = z.array(issueSchema);
const commentListSchema = z.array(commentSchema);

export type RemediationStatus =
  | 'requested'
  | 'pr-opened'
  | 'existing-pr'
  | 'not-needed'
  | 'failed';

export interface AppJwtSigner {
  signDigest(digest: Uint8Array): Promise<Uint8Array>;
}

export class KeyVaultAppJwtSigner implements AppJwtSigner {
  private readonly credential: TokenCredential;
  private readonly keyClient: KeyClient;
  private readonly keyName: string;

  constructor(keyUri: string, credential: TokenCredential = new DefaultAzureCredential()) {
    const parsed = new URL(keyUri);
    const keyMatch = parsed.pathname.match(/^\/keys\/([0-9A-Za-z-]{1,127})$/);
    if (
      parsed.protocol !== 'https:' ||
      !parsed.hostname.endsWith('.vault.azure.net') ||
      !keyMatch
    ) {
      throw new Error('GitHub App signing key URI must be an unversioned Azure Key Vault key URI');
    }
    this.credential = credential;
    this.keyName = keyMatch[1];
    this.keyClient = new KeyClient(parsed.origin, credential);
  }

  async signDigest(digest: Uint8Array): Promise<Uint8Array> {
    const key: KeyVaultKey = await this.keyClient.getKey(this.keyName);
    const client = new CryptographyClient(key, this.credential);
    const signature = await client.sign('RS256', digest);
    return signature.result;
  }
}

type Fetch = typeof fetch;

export class GitHubRemediationClient {
  private cachedToken?: { value: string; refreshAfter: number };
  private createIssueInFlight?: Promise<{
    issueNumber: number;
    issueUrl: string;
    created: boolean;
  }>;

  constructor(
    private readonly config: BrokerConfig,
    private readonly appJwtSigner: AppJwtSigner,
    private readonly fetchImplementation: Fetch = fetch
  ) {}

  async createRemediationIssue(): Promise<{
    issueNumber: number;
    issueUrl: string;
    created: boolean;
  }> {
    if (this.createIssueInFlight) {
      return this.createIssueInFlight;
    }

    const operation = this.createRemediationIssueOnce();
    this.createIssueInFlight = operation;
    try {
      return await operation;
    } finally {
      if (this.createIssueInFlight === operation) {
        this.createIssueInFlight = undefined;
      }
    }
  }

  private async createRemediationIssueOnce(): Promise<{
    issueNumber: number;
    issueUrl: string;
    created: boolean;
  }> {
    const existing = await this.findExistingIssue();
    if (existing) {
      return {
        issueNumber: existing.number,
        issueUrl: existing.html_url,
        created: false
      };
    }

    await this.ensureRemediationLabel();
    const issue = await this.githubRequest(
      `/repos/${this.repositoryPath()}/issues`,
      issueSchema,
      {
        method: 'POST',
        body: JSON.stringify({
          title: ISSUE_TITLE,
          body: ISSUE_BODY,
          labels: [ISSUE_LABEL]
        })
      }
    );
    return {
      issueNumber: issue.number,
      issueUrl: issue.html_url,
      created: true
    };
  }

  async getRemediationStatus(issueNumber: number): Promise<{
    issueNumber: number;
    issueUrl: string;
    issueState: 'open' | 'closed';
    remediationStatus: RemediationStatus;
    resultCommentUrl?: string;
  }> {
    const issue = await this.githubRequest(
      `/repos/${this.repositoryPath()}/issues/${issueNumber}`,
      issueSchema
    );
    this.assertRemediationIssue(issue);

    const comments = await this.githubRequest(
      `/repos/${this.repositoryPath()}/issues/${issueNumber}/comments?per_page=100`,
      commentListSchema
    );

    const trustedResults = comments
      .filter(comment => comment.user.login === 'github-actions[bot]')
      .map(comment => ({
        comment,
        status: parseResultMarker(comment.body)
      }))
      .filter(
        (
          result
        ): result is {
          comment: z.infer<typeof commentSchema>;
          status: Exclude<RemediationStatus, 'requested'>;
        } => result.status !== undefined
      );
    const latest = trustedResults.at(-1);

    return {
      issueNumber: issue.number,
      issueUrl: issue.html_url,
      issueState: issue.state,
      remediationStatus: latest?.status ?? 'requested',
      ...(latest && { resultCommentUrl: latest.comment.html_url })
    };
  }

  private async findExistingIssue(): Promise<z.infer<typeof issueSchema> | undefined> {
    const issues = await this.githubRequest(
      `/repos/${this.repositoryPath()}/issues?state=open&labels=${encodeURIComponent(ISSUE_LABEL)}&per_page=100`,
      issueListSchema
    );
    return issues.find(issue => {
      try {
        this.assertRemediationIssue(issue);
        return true;
      } catch {
        return false;
      }
    });
  }

  private assertRemediationIssue(issue: z.infer<typeof issueSchema>): void {
    const labels = issue.labels.map(label =>
      typeof label === 'string' ? label : label.name
    );
    if (
      issue.title !== ISSUE_TITLE ||
      !issue.body?.includes(ISSUE_MARKER) ||
      issue.user.login !== this.config.githubAppBotLogin ||
      !labels.includes(ISSUE_LABEL)
    ) {
      throw new Error('Issue is not a valid Scenario C remediation request');
    }
  }

  private async ensureRemediationLabel(): Promise<void> {
    const labelPath = `/repos/${this.repositoryPath()}/labels/${encodeURIComponent(ISSUE_LABEL)}`;
    const existing = await this.githubFetch(labelPath);
    if (existing.ok) {
      const label = labelSchema.parse(await existing.json());
      if (label.name !== ISSUE_LABEL) {
        throw new Error('GitHub returned an unexpected remediation label');
      }
      return;
    }
    if (existing.status !== 404) {
      throw new Error(
        `GitHub label lookup failed with status ${existing.status}`
      );
    }

    await this.githubRequest(
      `/repos/${this.repositoryPath()}/labels`,
      labelSchema,
      {
        method: 'POST',
        body: JSON.stringify({
          name: ISSUE_LABEL,
          color: 'b60205',
          description: 'Fixed-contract Scenario C SRE remediation request'
        })
      }
    );
  }

  private repositoryPath(): string {
    return `${encodeURIComponent(this.config.repositoryOwner)}/${encodeURIComponent(this.config.repositoryName)}`;
  }

  private async githubRequest<T>(
    path: string,
    schema: z.ZodType<T>,
    init: RequestInit = {}
  ): Promise<T> {
    const response = await this.githubFetch(path, init);
    if (!response.ok) {
      throw new Error(`GitHub API request failed with status ${response.status}`);
    }
    return schema.parse(await response.json());
  }

  private async githubFetch(
    path: string,
    init: RequestInit = {}
  ): Promise<Response> {
    const token = await this.getInstallationToken();
    return this.fetchImplementation(
      `https://api.github.com${path}`,
      {
        ...init,
        headers: {
          Accept: 'application/vnd.github+json',
          Authorization: `Bearer ${token}`,
          'Content-Type': 'application/json',
          'User-Agent': 'contosopay-sre-remediation-mcp/1.0',
          'X-GitHub-Api-Version': '2022-11-28',
          ...init.headers
        },
        signal: AbortSignal.timeout(10_000)
      }
    );
  }

  private async getInstallationToken(): Promise<string> {
    const now = Date.now();
    if (this.cachedToken && now < this.cachedToken.refreshAfter) {
      return this.cachedToken.value;
    }

    const appJwt = await this.createAppJwt();
    const response = await this.fetchImplementation(
      `https://api.github.com/app/installations/${this.config.githubAppInstallationId}/access_tokens`,
      {
        method: 'POST',
        headers: {
          Accept: 'application/vnd.github+json',
          Authorization: `Bearer ${appJwt}`,
          'Content-Type': 'application/json',
          'User-Agent': 'contosopay-sre-remediation-mcp/1.0',
          'X-GitHub-Api-Version': '2022-11-28'
        },
        body: JSON.stringify({
          repositories: [this.config.repositoryName],
          permissions: { issues: 'write' }
        }),
        signal: AbortSignal.timeout(10_000)
      }
    );
    if (!response.ok) {
      throw new Error(
        `GitHub installation token request failed with status ${response.status}`
      );
    }

    const token = installationTokenSchema.parse(await response.json());
    const expiration = Date.parse(token.expires_at);
    this.cachedToken = {
      value: token.token,
      refreshAfter: Math.min(expiration - 5 * 60_000, now + 50 * 60_000)
    };
    return token.token;
  }

  private async createAppJwt(): Promise<string> {
    const now = Math.floor(Date.now() / 1000);
    const header = encodeJson({ alg: 'RS256', typ: 'JWT' });
    const payload = encodeJson({
      iat: now - 60,
      exp: now + 9 * 60,
      iss: this.config.githubAppId
    });
    const unsignedToken = `${header}.${payload}`;
    const digest = createHash('sha256').update(unsignedToken, 'utf8').digest();
    const signature = await this.appJwtSigner.signDigest(digest);
    return `${unsignedToken}.${Buffer.from(signature).toString('base64url')}`;
  }
}

function encodeJson(value: object): string {
  return Buffer.from(JSON.stringify(value)).toString('base64url');
}

function parseResultMarker(
  body: string
): Exclude<RemediationStatus, 'requested'> | undefined {
  const match = body.match(
    /<!-- sre-remediation-result:(pr-opened|existing-pr|not-needed|failed) -->/
  );
  return match?.[1] as Exclude<RemediationStatus, 'requested'> | undefined;
}

export const remediationIssueContract = {
  title: ISSUE_TITLE,
  label: ISSUE_LABEL,
  marker: ISSUE_MARKER
} as const;
