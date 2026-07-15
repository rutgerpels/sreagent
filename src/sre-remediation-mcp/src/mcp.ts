import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { z } from 'zod';

export interface RemediationClient {
  createRemediationIssue(): Promise<{
    issueNumber: number;
    issueUrl: string;
    created: boolean;
  }>;
  getRemediationStatus(issueNumber: number): Promise<{
    issueNumber: number;
    issueUrl: string;
    issueState: 'open' | 'closed';
    remediationStatus:
      | 'requested'
      | 'pr-opened'
      | 'existing-pr'
      | 'not-needed'
      | 'failed';
    resultCommentUrl?: string;
  }>;
}

export function createMcpServer(client: RemediationClient): McpServer {
  const server = new McpServer({
    name: 'contosopay-sre-remediation',
    version: '1.0.0'
  });

  server.registerTool(
    'create_slow_leak_remediation_issue',
    {
      title: 'Request slow-leak remediation PR',
      description:
        'Creates the fixed, allowlisted Scenario B issue that asks GitHub Actions to open an unmerged slow-memory-leak remediation PR. Takes no repository content or shell input.',
      inputSchema: {},
      annotations: {
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false,
        readOnlyHint: false
      }
    },
    async () => {
      const result = await client.createRemediationIssue();
      return {
        content: [
          {
            type: 'text',
            text: result.created
              ? `Created remediation issue ${result.issueNumber}: ${result.issueUrl}`
              : `Reused existing remediation issue ${result.issueNumber}: ${result.issueUrl}`
          }
        ],
        structuredContent: result
      };
    }
  );

  server.registerTool(
    'get_slow_leak_remediation_status',
    {
      title: 'Check slow-leak remediation status',
      description:
        'Returns only validated status markers written by the trusted GitHub Actions workflow for a Scenario B remediation issue.',
      inputSchema: {
        issueNumber: z.number().int().positive()
      },
      annotations: {
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false,
        readOnlyHint: true
      }
    },
    async ({ issueNumber }) => {
      const result = await client.getRemediationStatus(issueNumber);
      return {
        content: [{ type: 'text', text: JSON.stringify(result) }],
        structuredContent: result
      };
    }
  );

  return server;
}
