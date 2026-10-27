import test from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import { spawn } from "node:child_process";
import fs from "node:fs";

const pause = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));

async function waitFor(check, message) {
  const deadline = Date.now() + 5_000;
  while (Date.now() < deadline) {
    const result = await check();
    if (result) return result;
    await pause(25);
  }
  assert.fail(message);
}

async function startFixture(t) {
  const directory = `/tmp/openusage-soft-limit-e2e-${crypto.randomUUID()}`;
  fs.mkdirSync(`${directory}/bin`, { recursive: true, mode: 0o700 });
  fs.writeFileSync(`${directory}/bin/codex`, `#!/usr/bin/env node
const fs = require("node:fs");
const socket = process.argv[process.argv.indexOf("--listen") + 1].replace("unix://", "");
const timer = setInterval(() => {}, 1000);
process.on("SIGTERM", () => {
  clearInterval(timer);
  fs.writeFileSync("fake-codex.exited", "");
  process.exit(0);
});
fs.writeFileSync("fake-codex.pid", String(process.pid));
fs.writeFileSync(socket, "");
`, { mode: 0o700 });
  const readyPath = `${directory}/ready.json`;
  const script = decodeURIComponent(new URL("./codex_soft_limit_server.mjs", import.meta.url).pathname);
  const fixture = spawn(process.execPath, [script, directory, `${directory}/control.sock`, readyPath], {
    env: { ...process.env, PATH: `${directory}/bin:${process.env.PATH}` },
    stdio: ["ignore", "ignore", "pipe"],
  });
  let stderr = "";
  let startupError;
  fixture.stderr.on("data", (data) => { stderr += data; });
  const exited = new Promise((resolve) => {
    fixture.once("exit", resolve);
    fixture.once("error", (error) => { startupError = error; resolve(); });
  });
  const clients = new Set();
  t.after(async () => {
    for (const client of clients) client.destroy();
    if (fixture.exitCode === null && fixture.signalCode === null) fixture.kill("SIGTERM");
    await Promise.race([exited, pause(3_500)]);
    if (fixture.exitCode === null && fixture.signalCode === null) {
      fixture.kill("SIGKILL");
      await Promise.race([exited, pause(500)]);
    }
    const pidPath = `${directory}/fake-codex.pid`;
    if (fs.existsSync(pidPath) && !fs.existsSync(`${directory}/fake-codex.exited`)) {
      try { process.kill(Number(fs.readFileSync(pidPath, "utf8")), "SIGKILL"); }
      catch (error) { if (error.code !== "ESRCH") throw error; }
    }
    fs.rmSync(directory, { recursive: true, force: true });
  });
  await waitFor(() => {
    if (startupError) throw startupError;
    assert.equal(fixture.exitCode, null, stderr);
    return fs.existsSync(readyPath);
  }, `Fixture startup timed out: ${stderr}`);
  const { port } = JSON.parse(fs.readFileSync(readyPath, "utf8"));

  function stats() {
    return new Promise((resolve, reject) => {
      const request = http.get(`http://127.0.0.1:${port}/stats`, (response) => {
        let body = "";
        response.on("data", (data) => { body += data; });
        response.on("error", reject);
        response.on("end", () => {
          try { resolve(JSON.parse(body)); } catch (error) { reject(error); }
        });
      });
      request.on("error", reject);
      request.setTimeout(1_000, () => request.destroy(new Error("Stats request timed out")));
    });
  }

  function open(threadId, turnId, text) {
    return new Promise((resolve, reject) => {
      const request = http.request(`http://127.0.0.1:${port}/v1/responses`, {
        method: "POST", headers: { "Content-Type": "application/json" },
      }, (response) => {
        response.on("error", reject);
        if (response.statusCode !== 200 || !response.headers["content-type"]?.startsWith("text/event-stream")) {
          response.resume();
          reject(new Error("Expected a successful SSE response"));
          return;
        }
        response.once("data", () => {
          request.setTimeout(0);
          resolve(request);
        });
        response.resume();
      });
      clients.add(request);
      request.on("error", reject);
      request.setTimeout(1_000, () => request.destroy(new Error("Stream startup timed out")));
      request.end(JSON.stringify({
        model: "soft-limit-fixture", stream: true,
        client_metadata: { thread_id: threadId, turn_id: turnId },
        input: [{ role: "user", content: [{ type: "input_text", text }] }],
      }));
    });
  }

  async function closedCount(expected) {
    return waitFor(async () => {
      const value = await stats();
      return value.closed === expected && value;
    }, `Expected ${expected} closed streams`);
  }
  return { open, stats, closedCount };
}

test("background streams cannot replace either user turn in stream accounting", { timeout: 15_000 }, async (t) => {
  const fixture = await startFixture(t);
  const first = await fixture.open("user-a", "turn-a", "Harmless local Soft Limit cancellation fixture.");
  const title = await fixture.open("title-thread", "title-turn", "Generate a concise, single-line task title.");
  let stats = await fixture.stats();
  assert.equal(stats.opened, 2);
  assert.ok(Array.isArray(stats.requests), "Stats must identify individual streams");
  assert.deepEqual(stats.requests.map(({ threadId, turnId }) => [threadId, turnId]), [
    ["user-a", "turn-a"], ["title-thread", "title-turn"],
  ]);
  assert.equal(stats.requests.some((request) => request.threadId === "user-b"), false);

  const second = await fixture.open("user-b", "turn-b", "Harmless local terminal cancellation fixture.");
  first.destroy();
  title.destroy();
  stats = await fixture.closedCount(2);
  assert.equal(stats.opened, 3);
  assert.equal(new Set(stats.requests.map((request) => request.id)).size, 3);
  assert.equal(stats.requests.find((request) => request.threadId === "user-a").closed, true);
  assert.equal(stats.requests.find((request) => request.threadId === "user-b").closed, false);

  second.destroy();
  stats = await fixture.closedCount(3);
  const users = stats.requests.filter((request) => ["user-a", "user-b"].includes(request.threadId));
  assert.equal(users.length, 2);
  assert.equal(users.every((request) => request.closed), true);
});

test("retries retain separate closure state for the same turn", { timeout: 15_000 }, async (t) => {
  const fixture = await startFixture(t);
  const first = await fixture.open("same-thread", "same-turn", "Harmless retry fixture.");
  const retry = await fixture.open("same-thread", "same-turn", "Harmless retry fixture.");
  let stats = await fixture.stats();
  assert.ok(Array.isArray(stats.requests), "Stats must identify individual streams");
  assert.equal(stats.requests.length, 2);
  assert.equal(new Set(stats.requests.map((request) => request.id)).size, 2);
  assert.equal(stats.requests.every((request) => request.threadId === "same-thread" && request.turnId === "same-turn"), true);

  first.destroy();
  stats = await fixture.closedCount(1);
  assert.equal(stats.requests.filter((request) => request.closed).length, 1);
  assert.equal(stats.requests.filter((request) => !request.closed).length, 1);

  retry.destroy();
  stats = await fixture.closedCount(2);
  assert.equal(stats.requests.every((request) => request.closed), true);
});
