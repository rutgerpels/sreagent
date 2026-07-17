import { createApp } from './app.js';
import { EntraAccessTokenVerifier } from './auth.js';
import { loadConfig } from './config.js';
import {
  GitHubRemediationClient,
  KeyVaultAppJwtSigner
} from './github.js';

const config = loadConfig();
const appJwtSigner = new KeyVaultAppJwtSigner(config.privateKeyUri);
const githubClient = new GitHubRemediationClient(config, appJwtSigner);
const accessTokenVerifier = await EntraAccessTokenVerifier.create(
  config.entraTenantId,
  config.entraTokenAudience
);
const app = createApp(config, githubClient, accessTokenVerifier);

const listener = app.listen(config.port, () => {
  console.info(
    JSON.stringify({
      event: 'server_started',
      port: config.port
    })
  );
});

function shutdown(signal: string): void {
  console.info(JSON.stringify({ event: 'server_stopping', signal }));
  listener.close(error => {
    if (error) {
      console.error(
        JSON.stringify({ event: 'server_stop_failed', error: error.message })
      );
      process.exitCode = 1;
    }
  });
}

process.on('SIGINT', () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));
