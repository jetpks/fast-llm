# frozen_string_literal: true

# BYTE-PARITY harness (Specification §12.2–§12.3; AC2). The 13 canonical
# request bodies recorded from REAL pi (11 from the installed
# @earendil-works/pi-ai 1.1.0 dist, driven hermetically — provenance:
# fixtures/wire/CAPTURE.mjs; plus the two I63 strict-sampling scenarios
# from the 1.2.0 dist — fixtures/wire/CAPTURE-STRICT.mjs; frozen digests
# in the drivers' headers + the table below) are replayed through the
# gem's PUBLIC surface: the exact §12.3 gem-side construction runs ONE
# request per scenario through Chat → Client → Protocol against the gem's
# own MockLLMServer (§12.1), and the captured request body must be
# BYTE-IDENTICAL to the fixture's request_body (string equality + SHA256
# against the frozen digest table). A NameError-shaped near-miss is not a
# pass: every assertion here is on real bytes.
#
# Capture-fidelity note (why a re-serialization appears below): the
# MockLLMServer stores request bodies PARSED (its tart lineage, §12.1 —
# the mock is lane core's file). The comparison re-serializes the captured
# Hash with JSON.generate; Ruby hashes preserve insertion order and
# JSON.parse preserves document order, so the round-trip reproduces these
# compact ASCII wire bytes exactly — any gem-side key-order, presence, or
# value defect still fails both the string and the digest assertion. The
# only bytes invisible to this capture are formatting-style bytes the mock
# itself already erased on capture.
require "digest"
require "json"
require "fast/completions"
require_relative "../../support/mock_llm_server"

# The §12.3 tool, under a named class (Tool derives the wire name from
# tool_name; §11). parameters are emitted VERBATIM (§9.2) — the literal's
# key order below IS the fixture's key order.
class ParityReadTool < Fast::Completions::Tool
  description "Read file contents."
  tool_name "read"
  parameters(
    "type" => "object",
    "required" => ["path"],
    "properties" => {
      "path" => {"type" => "string"},
      "offset" => {"type" => "number"},
    },
  )

  # Parity scenarios replay pre-built history; the scripted reply never
  # asks for tools, so this never runs.
  def execute(path:, offset: nil)
    "parity harness: tool not executed"
  end
end

# The §12.3 tool with an I63 constrained_sampling declaration — the
# strict-rewrite scenario (same parameters literal as ParityReadTool; the
# declared Hash must NOT be what reaches the wire).
class StrictReadTool < Fast::Completions::Tool
  description "Read file contents."
  tool_name "read"
  parameters(
    "type" => "object",
    "required" => ["path"],
    "properties" => {
      "path" => {"type" => "string"},
      "offset" => {"type" => "number"},
    },
  )
  constrained_sampling("type" => "json_schema", "strict" => "prefer")

  def execute(path:, offset: nil)
    "parity harness: tool not executed"
  end
end

RSpec.describe "Fast::Completions wire parity — recorded pi fixtures (§12.2–§12.3)" do
  FIXTURE_DIR = File.expand_path("../../fixtures/wire", __dir__)

  # FROZEN (Grounds §3 / AC2 wire-fixtures-digests): SHA256 of each
  # fixture's request_body. Table order = the frozen scenario order.
  FROZEN_DIGESTS = {
    "fireworks_plain" => "0b9da927d3cab0b8b41ecb634fde099729e03f817ef6ba3aba26720df2130d93",
    "openai_ladder_on" => "b05b45aeb3a4f7bdfa12d142e839882855688a246ead4d016fbe474188dfaed2",
    "openai_ladder_off" => "60914406494e2e8403de6b932f01cd5d901c9ae4c4de75e283b25656fa6304b1",
    "zai_on" => "9a23aee6b115cce0bd6a608465f2c56332123e47a0f22c491793c0a4d0e45c13",
    "zai_off" => "88dd5af69ceb68bbc41aad9ddfbc4dcb36e0dd66fec3563054d484cc0f727f7c",
    "deepseek_on" => "ce98edaee2ecb634dcd4461e3e56cfc4f973cd37026fc390b63ac2bdfbfec5f5",
    "tool_roundtrip" => "940d8f5b262f59a3db7b27a70471ac96a40c170264edc83219bef83dce1e9038",
    "thinking_replay" => "c9259d5da9ca8c63186522c24b9bdfd1fe81aa0903187b0f50634b56eb3c7e6c",
    "reasoning_details_replay" => "c21da08d520e246652b33bedf76d89db581692a7775de5181dc8c63013a0ae4e",
    "cross_model_thinking_replay" => "809a9b7ecc99399379031524ed5810677e31c22cac2f64eb6e728602ea5939fc",
    "budget_field" => "fb29e70650e9708f394c319d3c8ecacb840c134d214f9ce2747151356b86d1b7",
    "zai_strict_tool" => "d7470202a2f66216b3d0381bb18d3c5c29082e5c334b7fb87c2410d65ce824a8",
    "zai_strict_undeclared" => "fead3755e34689d502cbb865d6d424ccc84b4453d8724aa8fee713f9516a60c9",
  }.freeze
  TAGS = FROZEN_DIGESTS.keys.freeze

  # The §12.3 budget dialect, declared in the spec itself under a fresh
  # name (never collides with the shipped trio; §12.3). Re-declaring is
  # idempotent (last declaration wins, §4).
  Fast::Completions.dialect(:budget_probe) do
    thinking_token_budget_field "thinking_token_budget"
  end

  # HARNESS-LOCAL capture-era compat (architect ruling on the I63
  # PHASE-0-class conflict — never enters dialects.rb's shipped registry;
  # the shipped trio stays :zai/:deepseek/:fireworks). The zai_on/zai_off
  # fixtures are pi-ai 1.1.0 captures, from BEFORE strict emission existed
  # on this surface: pi 1.2.0 — the generation the two I63 captures come
  # from — emits ,"strict":false on exactly this wire (undeclared §12.3
  # read tool, strict-capable zai compat; 501B → 516B, proof fixture
  # zai_strict_undeclared, SHA256 fead3755e34689d502cbb865d6d424ccc84b4453
  # d8724aa8fee713f9516a60c9). The 1.1.0 bytes are therefore reproducible
  # only against the capture-era compat: :zai_1_1 is :zai minus
  # supports_strict_mode (the vocabulary default false). The I63 rows use
  # the shipped :zai.
  Fast::Completions.dialect(:zai_1_1) do
    thinking_format :zai
    zai_tool_stream true
    max_tokens_field "max_tokens"
    supports_developer_role false
    supports_reasoning_effort true
    supports_store false
  end

  # The §12.3 scenario table, verbatim: model kwargs beyond the common
  # {id: "mock-1", context_window: 128_000}, the chat thinking level, the
  # history before the final user message, and that final user message
  # ("hello" for the no-history rows; the replay rows end with "thanks").
  # Same-model replay stamping (§12.3 note): the model carries
  # provider: "mock" and the replayed assistants are stamped to match;
  # tool_roundtrip stamps its assistant provider: "fireworks" per the
  # frozen table (no thinking blocks — byte-equivalent either way).
  SCENARIOS = {
    "fireworks_plain" => {
      model: {reasoning: false, max_tokens: 512, dialect: :fireworks},
      thinking_level: nil,
      history: -> { [] },
      final_user: "hello",
    },
    "openai_ladder_on" => {
      model: {reasoning: true, max_tokens: 512,
              thinking_level_map: {off: "none", low: "low", medium: "medium", high: "high"}},
      thinking_level: :high,
      history: -> { [] },
      final_user: "hello",
    },
    "openai_ladder_off" => {
      model: {reasoning: true, max_tokens: 512,
              thinking_level_map: {off: "none", low: "low", medium: "medium", high: "high"}},
      thinking_level: :off,
      history: -> { [] },
      final_user: "hello",
    },
    "zai_on" => {
      model: {reasoning: true, max_tokens: 512, dialect: :zai_1_1, # capture-era compat; see the :zai_1_1 declaration
              thinking_level_map: {off: "disabled", low: "low", medium: "medium", high: "high"}},
      thinking_level: :high,
      history: -> { [] },
      final_user: "hello",
    },
    "zai_off" => {
      model: {reasoning: true, max_tokens: 512, dialect: :zai_1_1, # capture-era compat; see the :zai_1_1 declaration
              thinking_level_map: {off: "disabled", low: "low", medium: "medium", high: "high"}},
      thinking_level: :off,
      history: -> { [] },
      final_user: "hello",
    },
    "deepseek_on" => {
      model: {reasoning: true, max_tokens: 512, dialect: :deepseek,
              thinking_level_map: {off: "disabled", high: "high"}},
      thinking_level: :high,
      history: -> { [] },
      final_user: "hello",
    },
    "tool_roundtrip" => {
      model: {reasoning: false, max_tokens: 512, dialect: :fireworks},
      thinking_level: nil,
      history: lambda {
        [
          Fast::Completions::Message.user("read the file"),
          Fast::Completions::Message.assistant(
            [{type: :tool_call, id: "call_1", name: "read", arguments: {"path" => "src.rb"}}],
            provider: "fireworks", model: "mock-1",
          ),
          Fast::Completions::Message.tool_result(tool_call_id: "call_1", content: "line 1\nline 2"),
        ]
      },
      final_user: "thanks",
    },
    "thinking_replay" => {
      model: {reasoning: true, max_tokens: 512, provider: "mock",
              thinking_level_map: {high: "high"}},
      thinking_level: nil,
      history: lambda {
        [
          Fast::Completions::Message.user("hello"),
          Fast::Completions::Message.assistant(
            [{type: :thinking, thinking: "let me think", signature: "reasoning_content"},
             {type: :text, text: "Hi!"}],
            provider: "mock", model: "mock-1",
          ),
        ]
      },
      final_user: "thanks",
    },
    "reasoning_details_replay" => {
      model: {reasoning: true, max_tokens: 512, provider: "mock",
              thinking_level_map: {high: "high"}},
      thinking_level: nil,
      history: lambda {
        [
          Fast::Completions::Message.user("hello"),
          # The signature is a STRING that parses as a valid detail array
          # — it replays as `reasoning_details` (§9.5).
          Fast::Completions::Message.assistant(
            [{type: :thinking, thinking: "thought",
              signature: '[{"type":"reasoning.text","text":"t1","signature":"sig"}]'},
             {type: :text, text: "Hi!"}],
            provider: "mock", model: "mock-1",
          ),
        ]
      },
      final_user: "thanks",
    },
    "cross_model_thinking_replay" => {
      model: {reasoning: true, max_tokens: 512, provider: "mock",
              thinking_level_map: {high: "high"}},
      thinking_level: nil,
      history: lambda {
        [
          Fast::Completions::Message.user("hello"),
          Fast::Completions::Message.assistant(
            [{type: :thinking, thinking: "let me think", signature: "reasoning_content"},
             {type: :text, text: "Hi!"}],
            provider: "other-provider", model: "mock-1",
          ),
        ]
      },
      final_user: "thanks",
    },
    "budget_field" => {
      model: {reasoning: true, max_tokens: 4096, dialect: :budget_probe,
              thinking_level_map: {off: "none", high: "high"}},
      thinking_level: :high,
      history: -> { [] },
      final_user: "hello",
    },
    # I63 strict rows (pi capture 1.2.0): the zai_on model shape; the
    # declared-strict row uses StrictReadTool, the undeclared row the
    # plain ParityReadTool.
    "zai_strict_tool" => {
      model: {reasoning: true, max_tokens: 512, dialect: :zai,
              thinking_level_map: {off: "disabled", low: "low", medium: "medium", high: "high"}},
      thinking_level: :high,
      history: -> { [] },
      final_user: "hello",
      tool_class: StrictReadTool,
    },
    "zai_strict_undeclared" => {
      model: {reasoning: true, max_tokens: 512, dialect: :zai,
              thinking_level_map: {off: "disabled", low: "low", medium: "medium", high: "high"}},
      thinking_level: :high,
      history: -> { [] },
      final_user: "hello",
      tool_class: ParityReadTool,
    },
  }.freeze

  # Fixture fidelity (the in-suite half of AC2 wire-fixtures-digests): the
  # committed bytes ARE the frozen bytes — shape, path, digest.
  it "carries the 13 frozen fixtures: shape, request_path, digest" do
    TAGS.each do |tag|
      fixture = JSON.parse(File.read(File.join(FIXTURE_DIR, "#{tag}.json")))
      expect(fixture.keys).to eq(%w[tag request_path request_body])
      expect(fixture.fetch("tag")).to eq(tag)
      expect(fixture.fetch("request_path")).to eq("/v1/chat/completions")
      expect(Digest::SHA256.hexdigest(fixture.fetch("request_body"))).to eq(FROZEN_DIGESTS.fetch(tag)),
        "fixture #{tag}.json does not carry the frozen bytes"
    end
  end

  TAGS.each do |tag|
    it "reproduces the recorded pi bytes for #{tag} (byte equality + frozen digest)" do
      fixture = JSON.parse(File.read(File.join(FIXTURE_DIR, "#{tag}.json")))
      captured = run_scenario(SCENARIOS.fetch(tag))
      expected = fixture.fetch("request_body")

      report = parity_failure_report(expected, captured) unless captured == expected
      expect(captured).to(eq(expected), report)
      expect(Digest::SHA256.hexdigest(captured)).to eq(FROZEN_DIGESTS.fetch(tag))
    end
  end

  # ONE request per scenario (the driver's discipline, CAPTURE.mjs), run
  # through the full public path; returns the captured body as bytes.
  def run_scenario(scenario)
    server = MockLLMServer.new
    server.script([{type: :stream, content: "ok"}])
    server.start
    client = Fast::Completions::Client.new(base_url: server.url, api_key: "parity-key")
    begin
      chat = Fast::Completions::Chat.new(client: client, model: build_model(scenario))
      chat.with_instructions("You are a test assistant.")
      chat.with_tools((scenario[:tool_class] || ParityReadTool).new)
      chat.with_thinking_level(scenario[:thinking_level]) if scenario[:thinking_level]
      scenario[:history].call.each { |message| chat.add_message(message) }
      chat.add_message(Fast::Completions::Message.user(scenario[:final_user]))
      Async { chat.step }
    ensure
      client.close rescue nil
      server.stop
    end

    bodies = server.captured_requests
    expect(bodies.size).to eq(1), "expected exactly one request for the scenario"
    JSON.generate(bodies.first) # order-faithful round-trip; see the header note
  end

  def build_model(scenario)
    Fast::Completions::Model.new(**{id: "mock-1", context_window: 128_000}.merge(scenario[:model]))
  end

  # The §12.2 usability pin: on mismatch, a KEY-ORDER-AWARE diff — each
  # parsed body rendered as ordered key-path lines, zipped line by line so
  # the first reordered/renamed/divergent key is flagged — plus the byte
  # sizes and the first divergent byte offset.
  def parity_failure_report(expected, actual)
    expected_lines = key_path_lines(JSON.parse(expected))
    actual_lines = key_path_lines(JSON.parse(actual))
    rows = Array.new([expected_lines.size, actual_lines.size].max) do |i|
      e = expected_lines[i] || "≪end of expected≫"
      a = actual_lines[i] || "≪end of actual≫"
      "#{e == a ? "    " : "!   "}#{e}\n    #{a}"
    end
    <<~REPORT
      byte mismatch: expected #{expected.bytesize}B, got #{actual.bytesize}B; first divergent byte at offset #{first_byte_mismatch(expected, actual)}
      key-order-aware diff (expected line over actual line):
      #{rows.join("\n")}
    REPORT
  end

  def key_path_lines(node, path = "$")
    case node
    when Hash then node.flat_map { |key, value| key_path_lines(value, "#{path}.#{key}") }
    when Array then node.each_with_index.flat_map { |value, index| key_path_lines(value, "#{path}[#{index}]") }
    else ["#{path} = #{node.inspect}"]
    end
  end

  def first_byte_mismatch(expected, actual)
    limit = [expected.bytesize, actual.bytesize].min
    limit.times { |i| return i if expected.getbyte(i) != actual.getbyte(i) }
    limit
  end
end
