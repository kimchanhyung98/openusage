import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { spawn } from "node:child_process";

const [fixtureHome, socketPath, readyPath] = process.argv.slice(2);
if (!fixtureHome?.startsWith("/tmp/openusage-soft-limit-e2e-") || !socketPath?.startsWith(`${fixtureHome}/`)) {
  throw new Error("A dedicated Soft Limit fixture directory is required");
}

let opened = 0;
let closed = 0;
const sockets = new Set();
const streams = new Set();
const api = http.createServer((request, response) => {
  if (request.url === "/stats") {
    response.setHeader("Content-Type", "application/json");
    response.end(JSON.stringify({ opened, closed }));
    return;
  }
  if (request.method === "GET") {
    response.setHeader("Content-Type", "application/json");
    response.end(JSON.stringify({ data: [], models: [] }));
    return;
  }
  request.resume();
  request.on("end", () => {
    opened += 1;
    streams.add(response);
    response.writeHead(200, { "Content-Type": "text/event-stream", "Cache-Control": "no-cache" });
    response.write(`event: response.created\ndata: ${JSON.stringify({
      type: "response.created",
      response: { id: `soft-limit-${opened}`, object: "response", status: "in_progress", output: [] },
    })}\n\n`);
    const itemID = `soft-limit-message-${opened}`;
    response.write(`event: response.output_item.added\ndata: ${JSON.stringify({
      type: "response.output_item.added", output_index: 0,
      item: { id: itemID, type: "message", role: "assistant", status: "in_progress", content: [] },
    })}\n\n`);
    const heartbeat = setInterval(() => response.write(`event: response.output_text.delta\ndata: ${JSON.stringify({
      type: "response.output_text.delta", item_id: itemID, output_index: 0, content_index: 0, delta: " fixture",
    })}\n\n`), 100);
    response.on("close", () => {
      clearInterval(heartbeat);
      streams.delete(response);
      closed += 1;
    });
  });
});
api.on("connection", (socket) => {
  sockets.add(socket);
  socket.on("close", () => sockets.delete(socket));
});
await new Promise((resolve) => api.listen(0, "127.0.0.1", resolve));
const port = api.address().port;

const config = `
model = "soft-limit-fixture"
model_provider = "openai"
openai_base_url = "http://127.0.0.1:${port}/v1"
approval_policy = "never"
sandbox_mode = "read-only"
web_search = "disabled"
check_for_update_on_startup = false
[analytics]
enabled = false
[projects."${fs.realpathSync(fixtureHome)}"]
trust_level = "trusted"
${fs.realpathSync(fixtureHome) !== fixtureHome ? `[projects."${fixtureHome}"]\ntrust_level = "trusted"` : ""}
`;
fs.writeFileSync(path.join(fixtureHome, "config.toml"), config, { flag: "wx", mode: 0o600 });
fs.writeFileSync(path.join(fixtureHome, "auth.json"), JSON.stringify({ OPENAI_API_KEY: "sk-openusage-local-fixture" }), { flag: "wx", mode: 0o600 });
const server = spawn("codex", ["app-server", "--strict-config", "--listen", `unix://${socketPath}`], {
  cwd: fixtureHome,
  env: { PATH: process.env.PATH, CODEX_HOME: fixtureHome, LANG: "en_US.UTF-8", CODEX_INTERNAL_APP_SERVER_REMOTE_CONTROL_DISABLED: "1" },
  stdio: ["ignore", "ignore", "inherit"],
});
server.on("error", (error) => { process.stderr.write(`${error.message}\n`); process.exit(1); });
server.on("exit", (code) => { if (!stopping) process.exit(code || 1); });
let stopping = false;
const timer = setInterval(() => {
  if (!fs.existsSync(socketPath)) return;
  clearInterval(timer);
  fs.writeFileSync(readyPath, JSON.stringify({ port, socketPath }), { flag: "wx", mode: 0o600 });
}, 50);

function stop() {
  if (stopping) return;
  stopping = true;
  clearInterval(timer);
  for (const stream of streams) stream.end();
  for (const socket of sockets) socket.destroy();
  api.close();
  server.kill("SIGTERM");
  server.once("exit", () => process.exit(0));
  setTimeout(() => process.exit(1), 3000).unref();
}
process.on("SIGTERM", stop);
process.on("SIGINT", stop);
