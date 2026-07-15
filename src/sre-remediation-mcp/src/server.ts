import { createApp } from './app';
import { loadConfig } from './config';
import {
  GitHubRemediationClient,
  KeyVaultPrivateKeyProvider
} from './github';

const config = loadConfig();
const privateKeyProvider = new KeyVaultPrivateKeyProvider(
  config.keyVaultUrl,
  config.privateKeySecretName
);
const githubClient = new GitHubRemediationClient(config, privateKeyProvider);
const app = createApp(config, githubClient);

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
