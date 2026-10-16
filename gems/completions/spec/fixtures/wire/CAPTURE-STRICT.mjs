// I63 strict-sampling capture — drives REAL pi (installed
// @earendil-works/pi-coding-agent 1.2.0 / pi-ai dist — the same compiled
// wire code class the I51 capture used; constrained-sampling surface
// verified identical across 1.1.0/1.2.0/1.3.0 during the 2026-10-15
// root-cause) against a hermetic TCP mock, one fixture per scenario.
// Scenarios: zai-shape compat + supportsStrictMode:true, the §12.3 read
// tool with constrainedSampling {type:"json_schema", strict:"prefer"}
// (declared) and without (undeclared).
import { streamSimple } from "/Users/eric/.local/share/mise/installs/node/24.18.0/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/@earendil-works/pi-ai/dist/api/openai-completions.js";
import { createServer } from "node:net";
import { createHash } from "node:crypto";
import { writeFileSync, mkdirSync } from "node:fs";

const outDir = process.argv[2] ?? "tmp/i63-spec/capture/out";
mkdirSync(outDir, { recursive: true });

const captured = [];
const server = createServer((socket) => {
  let pending = Buffer.alloc(0);
  let started = false;
  socket.on("data", (chunk) => {
    pending = Buffer.concat([pending, chunk]);
    if (started) return;
    const headEnd = pending.indexOf("\r\n\r\n");
    if (headEnd === -1) return;
    const head = pending.slice(0, headEnd).toString("utf8");
    const m = /content-length:\s*(\d+)/i.exec(head);
    if (!m) return;
    const total = headEnd + 4 + Number(m[1]);
    if (pending.length < total) return;
    started = true;
    const body = pending.slice(headEnd + 4, total).toString("utf8");
    const path = /^POST (\S+) HTTP/i.exec(head)?.[1] ?? "?";
    captured.push({ path, body });
    const sse = [
      'data: {"choices":[{"delta":{"role":"assistant"}}]}',
      "",
      'data: {"choices":[{"delta":{"content":"ok"}}]}',
      "",
      'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}',
      "",
      'data: {"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}',
      "",
      "data: [DONE]",
      "",
      "",
    ].join("\n");
    const head2 = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\nContent-Length: " +
      Buffer.byteLength(sse) + "\r\n\r\n";
    socket.end(head2 + sse);
  });
});
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const port = server.address().port;
const baseUrl = `http://127.0.0.1:${port}/v1`;

const SYSTEM = "You are a test assistant.";
const USER = "hello";
const READ_TOOL = {
  name: "read",
  description: "Read file contents.",
  parameters: {
    type: "object",
    required: ["path"],
    properties: { path: { type: "string" }, offset: { type: "number" } },
  },
};
const READ_TOOL_STRICT = {
  ...READ_TOOL,
  constrainedSampling: { type: "json_schema", strict: "prefer" },
};

const baseModel = (over = {}) => ({
  id: "mock-1",
  name: "Mock 1",
  api: "openai-completions",
  provider: "mock",
  baseUrl,
  input: ["text"],
  cost: { input: 0, output: 0 },
  contextWindow: 128000,
  maxTokens: 512,
  ...over,
});
const zaiStrictModel = baseModel({
  reasoning: true,
  thinkingLevelMap: { off: "disabled", low: "low", medium: "medium", high: "high" },
  compat: {
    thinkingFormat: "zai",
    zaiToolStream: true,
    maxTokensField: "max_tokens",
    supportsDeveloperRole: false,
    supportsReasoningEffort: true,
    supportsStore: false,
    supportsStrictMode: true,
  },
});

function systemMsg(tool) {
  return { role: "system", content: SYSTEM, toolsAdded: [tool], timestamp: 0 };
}
function userMsg(text = USER) {
  return { role: "user", content: text, timestamp: 0 };
}

const SCENARIOS = [
  {
    tag: "zai_strict_tool",
    model: zaiStrictModel,
    context: { messages: [systemMsg(READ_TOOL_STRICT), userMsg()] },
    options: { reasoning: "high" },
  },
  {
    tag: "zai_strict_undeclared",
    model: zaiStrictModel,
    context: { messages: [systemMsg(READ_TOOL), userMsg()] },
    options: { reasoning: "high" },
  },
];

const manifest = [];
for (const sc of SCENARIOS) {
  const before = captured.length;
  const events = [];
  try {
    const stream = streamSimple(sc.model, sc.context, { apiKey: "mock-key", ...sc.options });
    for await (const ev of stream) events.push(ev.type);
  } catch (error) {
    console.error(sc.tag, "THREW", error?.message);
  }
  if (captured.length !== before + 1) {
    console.error(sc.tag, "expected exactly one request, got", captured.length - before);
  }
  const { path, body } = captured[before];
  const digest = createHash("sha256").update(body, "utf8").digest("hex");
  manifest.push({ tag: sc.tag, path, digest, bytes: Buffer.byteLength(body), last_event: events.at(-1) });
  writeFileSync(`${outDir}/${sc.tag}.json`, JSON.stringify({ tag: sc.tag, request_path: path, request_body: body }, null, 2) + "\n");
  console.log(sc.tag, digest, events.at(-1));
}

writeFileSync(`${outDir}/manifest.json`, JSON.stringify(manifest, null, 2) + "\n");
server.close();
console.log("CAPTURE_DONE", manifest.length);
