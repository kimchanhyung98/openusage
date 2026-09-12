import { preview } from 'astro';

const port = Number(process.argv[2]);
if (!Number.isInteger(port) || port < 1024 || port > 65535) throw new Error('Invalid E2E server port');

// CLI의 자동 백그라운드 실행 없이 테스트 프로세스 수명에 서버를 연결.
const server = await preview({ server: { host: '127.0.0.1', port } });
if (server.port !== port) {
  await server.stop();
  throw new Error(`E2E port ${port} is already in use`);
}
for (const signal of ['SIGINT', 'SIGTERM']) {
  process.once(signal, async () => {
    await server.stop();
    process.exit(0);
  });
}
