import express, { type Express, type Request, type Response } from 'express';
import helmet from 'helmet';
import { StreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/streamableHttp.js';
import type { BrokerConfig } from './config';
import { authorizeCaller } from './auth';
import { createMcpServer, type RemediationClient } from './mcp';

export function createApp(
  config: BrokerConfig,
  githubClient: RemediationClient
): Express {
  const app = express();
  app.disable('x-powered-by');
  app.use(
    helmet({
      contentSecurityPolicy: {
        directives: {
          defaultSrc: ["'none'"],
          frameAncestors: ["'none'"]
        }
      }
    })
  );
  app.use(express.json({ limit: '64kb', type: 'application/json' }));

  app.get('/health', (_request, response) => {
    response.status(200).json({ status: 'ok' });
  });

  app.use('/mcp', authorizeCaller(config.allowedCallerPrincipalId));

  app.post('/mcp', async (request: Request, response: Response) => {
    const server = createMcpServer(githubClient);
    const transport = new StreamableHTTPServerTransport({
      sessionIdGenerator: undefined
    });

    try {
      await server.connect(transport);
      await transport.handleRequest(request, response, request.body);
    } catch (error) {
      console.error(
        JSON.stringify({
          event: 'mcp_request_failed',
          error: error instanceof Error ? error.message : 'Unknown error'
        })
      );
      if (!response.headersSent) {
        response.status(500).json({
          jsonrpc: '2.0',
          error: { code: -32603, message: 'Internal server error' },
          id: null
        });
      }
    } finally {
      await transport.close();
      await server.close();
    }
  });

  app.get('/mcp', (_request, response) => {
    response.status(405).set('Allow', 'POST').json({ error: 'Method not allowed' });
  });
  app.delete('/mcp', (_request, response) => {
    response.status(405).set('Allow', 'POST').json({ error: 'Method not allowed' });
  });

  return app;
}
