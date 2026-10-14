// I51 canonical pi wire capture — drives REAL pi (installed
// @earendil-works/pi-ai 1.1.0 dist — the same compiled wire code the parity
// rig's pi binary runs) against a hermetic TCP mock and records every request
// body VERBATIM, one fixture per scenario. No network, no API keys.
//
// Fixture = {tag, request_path, request_body (raw string)}. The byte-parity
// contract: Fast::Completions must produce byte-identical request bodies for
// the same scenario inputs.
//
// THIS FILE IS PROVENANCE ONLY — the suite never executes it (the fixtures
// are frozen bytes). It was run once, hermetically, on 2026-10-13; the
// staging copy at build/i51-harness/fixtures/ is its output + this driver.
// FROZEN DIGESTS (SHA256 of request_body; Grounds §3, AC2 wire-fixtures-digests):
//   fireworks_plain=0b9da927d3cab0b8b41ecb634fde099729e03f817ef6ba3aba26720df2130d93
//   openai_ladder_on=b05b45aeb3a4f7bdfa12d142e839882855688a246ead4d016fbe474188dfaed2
//   openai_ladder_off=60914406494e2e8403de6b932f01cd5d901c9ae4c4de75e283b25656fa6304b1
//   zai_on=9a23aee6b115cce0bd6a608465f2c56332123e47a0f22c491793c0a4d0e45c13
//   zai_off=88dd5af69ceb68bbc41aad9ddfbc4dcb36e0dd66fec3563054d484cc0f727f7c
//   deepseek_on=ce98edaee2ecb634dcd4461e3e56cfc4f973cd37026fc390b63ac2bdfbfec5f5
//   tool_roundtrip=940d8f5b262f59a3db7b27a70471ac96a40c170264edc83219bef83dce1e9038
//   thinking_replay=c9259d5da9ca8c63186522c24b9bdfd1fe81aa0903187b0f50634b56eb3c7e6c
//   reasoning_details_replay=c21da08d520e246652b33bedf76d89db581692a7775de5181dc8c63013a0ae4e
//   cross_model_thinking_replay=809a9b7ecc99399379031524ed5810677e31c22cac2f64eb6e728602ea5939fc
//   budget_field=fb29e70650e9708f394c319d3c8ecacb840c134d214f9ce2747151356b86d1b7
import { streamSimple } from "/Users/eric/.local/share/mise/installs/node/24.18.0/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/@earendil-works/pi-ai/dist/api/openai-completions.js";
import { createServer } from "node:net";
import { createHash } from "node:crypto";
import { writeFileSync, mkdirSync } from "node:fs";

const outDir = process.argv[2] ?? "tmp/i51-spec/capture/out";
mkdirSync(outDir, { recursive: true });

// ---- hermetic mock: one OpenAI SSE reply per request, body captured raw ----
const captured = [];
const server = createServer((socket) => {
  let buf = "";
  let body = null;
  socket.on("data", (chunk) => {
    buf += chunk;
    if (body === null) {
      const headEnd = buf.indexOf("\r\n\r\n");
      if (headEnd === -1) return;
      const head = buf.slice(0, headEnd);
      const cl = /content-length:\s*(\d+)/i.exec(head);
      body = buf.slice(headEnd + 4, headEnd + 4 + Number(cl?.[1] ?? 0));
      buf = buf.slice(headEnd + 4 + Number(cl?.[1] ?? 0));
    }
    if (body !== null && body.length === Number(/content-length:\s*(\d+)/i.exec(bufHead(socket, body))?.[1] ?? body.length)) {
      // body complete
    }
  });
});

// The streaming parser above is fiddly; simpler correct reader:
const server2 = createServer((socket) => {
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
server.close();

await new Promise((resolve) => server2.listen(0, "127.0.0.1", resolve));
const port = server2.address().port;
const baseUrl = `http://127.0.0.1:${port}/v1`;

// ---- fixed scenario inputs (byte-stable) ----
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

function systemMsg() {
  return { role: "system", content: SYSTEM, toolsAdded: [READ_TOOL], timestamp: 0 };
}
function userMsg(text = USER) {
  return { role: "user", content: text, timestamp: 0 };
}
function assistantMsg(content, identity = {}) {
  return {
    role: "assistant",
    content,
    api: "openai-completions",
    provider: "mock",
    model: "mock-1",
    usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, reasoning: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
    timestamp: 0,
    ...identity,
  };
}
function toolResultMsg(toolCallId, text, toolName = "read") {
  return { role: "toolResult", toolCallId, toolName, content: [{ type: "text", text }], timestamp: 0 };
}

const SCENARIOS = [
  {
    tag: "fireworks_plain",
    model: baseModel({ provider: "fireworks", reasoning: false }),
    context: { messages: [systemMsg(), userMsg()] },
    options: {},
  },
  {
    tag: "openai_ladder_on",
    model: baseModel({ reasoning: true, thinkingLevelMap: { off: "none", low: "low", medium: "medium", high: "high" } }),
    context: { messages: [systemMsg(), userMsg()] },
    options: { reasoning: "high" },
  },
  {
    tag: "openai_ladder_off",
    model: baseModel({ reasoning: true, thinkingLevelMap: { off: "none", low: "low", medium: "medium", high: "high" } }),
    context: { messages: [systemMsg(), userMsg()] },
    options: { reasoning: "off" },
  },
  {
    tag: "zai_on",
    model: baseModel({
      reasoning: true,
      thinkingLevelMap: { off: "disabled", low: "low", medium: "medium", high: "high" },
      compat: {
        thinkingFormat: "zai",
        zaiToolStream: true,
        maxTokensField: "max_tokens",
        supportsDeveloperRole: false,
        supportsReasoningEffort: true,
        supportsStore: false,
      },
    }),
    context: { messages: [systemMsg(), userMsg()] },
    options: { reasoning: "high" },
  },
  {
    tag: "zai_off",
    model: baseModel({
      reasoning: true,
      thinkingLevelMap: { off: "disabled", low: "low", medium: "medium", high: "high" },
      compat: {
        thinkingFormat: "zai",
        zaiToolStream: true,
        maxTokensField: "max_tokens",
        supportsDeveloperRole: false,
        supportsReasoningEffort: true,
        supportsStore: false,
      },
    }),
    context: { messages: [systemMsg(), userMsg()] },
    options: { reasoning: "off" },
  },
  {
    tag: "deepseek_on",
    model: baseModel({
      reasoning: true,
      thinkingLevelMap: { off: "disabled", high: "high" },
      compat: {
        thinkingFormat: "deepseek",
        maxTokensField: "max_tokens",
        supportsDeveloperRole: false,
        supportsReasoningEffort: true,
        requiresReasoningContentOnAssistantMessages: true,
        supportsStore: false,
      },
    }),
    context: { messages: [systemMsg(), userMsg()] },
    options: { reasoning: "high" },
  },
  {
    tag: "tool_roundtrip",
    model: baseModel({ provider: "fireworks", reasoning: false }),
    context: {
      messages: [
        systemMsg(),
        userMsg("read the file"),
        assistantMsg([{ type: "toolCall", id: "call_1", name: "read", arguments: { path: "src.rb" } }], { provider: "fireworks" }),
        toolResultMsg("call_1", "line 1\nline 2"),
        userMsg("thanks"),
      ],
    },
    options: {},
  },
  {
    tag: "thinking_replay",
    model: baseModel({ reasoning: true, thinkingLevelMap: { high: "high" } }),
    context: {
      messages: [
        systemMsg(),
        userMsg(),
        assistantMsg([
          { type: "thinking", thinking: "let me think", thinkingSignature: "reasoning_content" },
          { type: "text", text: "Hi!" },
        ]),
        userMsg("thanks"),
      ],
    },
    options: {},
  },
  {
    tag: "reasoning_details_replay",
    model: baseModel({ reasoning: true, thinkingLevelMap: { high: "high" } }),
    context: {
      messages: [
        systemMsg(),
        userMsg(),
        assistantMsg([
          {
            type: "thinking",
            thinking: "thought",
            thinkingSignature: JSON.stringify([{ type: "reasoning.text", text: "t1", signature: "sig" }]),
          },
          { type: "text", text: "Hi!" },
        ]),
        userMsg("thanks"),
      ],
    },
    options: {},
  },
  {
    tag: "cross_model_thinking_replay",
    model: baseModel({ reasoning: true, thinkingLevelMap: { high: "high" } }),
    context: {
      messages: [
        systemMsg(),
        userMsg(),
        assistantMsg(
          [
            { type: "thinking", thinking: "let me think", thinkingSignature: "reasoning_content" },
            { type: "text", text: "Hi!" },
          ],
          { provider: "other-provider" }
        ),
        userMsg("thanks"),
      ],
    },
    options: {},
  },
  {
    tag: "budget_field",
    model: baseModel({
      reasoning: true,
      thinkingLevelMap: { off: "none", high: "high" },
      maxTokens: 4096,
      compat: { thinkingTokenBudgetField: "thinking_token_budget" },
    }),
    context: { messages: [systemMsg(), userMsg()] },
    options: { reasoning: "high" },
  },
];

// ---- run ----
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
  console.log(sc.tag, digest.slice(0, 16), events.at(-1));
}

writeFileSync(`${outDir}/manifest.json`, JSON.stringify(manifest, null, 2) + "\n");
server2.close();
console.log("CAPTURE_DONE", manifest.length);
