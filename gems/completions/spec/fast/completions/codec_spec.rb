# frozen_string_literal: true

# Replay normalization pins (Specification §9.4-9.5; pi
# utils/transform-messages.ts + convertMessages openai-completions.ts
# :1300-1402). The byte-level counterparts live in the harness parity
# fixtures (thinking_replay, reasoning_details_replay,
# cross_model_thinking_replay, tool_roundtrip).
require "fast/completions"

RSpec.describe Fast::Completions::Codec do
  let(:model) do
    Fast::Completions::Model.new(id: "mock-1", reasoning: true, context_window: 128_000,
      max_tokens: 512, provider: "mock")
  end
  let(:dialect) { Fast::Completions::Dialect.new(nil) }

  def normalize(messages)
    described_class.normalize(messages, model)
  end

  def wire(instructions, messages)
    described_class.to_wire_messages(instructions, normalize(messages), model, dialect)
  end

  def assistant(blocks, provider: "mock", model_id: "mock-1", stop_reason: nil)
    Fast::Completions::Message.assistant(blocks, provider: provider, model: model_id, api: "openai-completions",
      stop_reason: stop_reason)
  end

  describe "thinking replay (same-model)" do
    it "keeps a signature-named field replay: reasoning_content (§9.5)" do
      history = [
        Fast::Completions::Message.user("hello"),
        assistant([{type: :thinking, thinking: "let me think", signature: "reasoning_content"},
                   {type: :text, text: "Hi!"}]),
        Fast::Completions::Message.user("thanks"),
      ]
      expect(wire(nil, history)[1]).to eq({role: "assistant", content: "Hi!", "reasoning_content" => "let me think"})
    end

    it "emits reasoning_details when the signature parses as a valid detail array (§9.5)" do
      signature = '[{"type":"reasoning.text","text":"t1","signature":"sig"}]'
      history = [
        assistant([{type: :thinking, thinking: "thought", signature: signature}, {type: :text, text: "Hi!"}]),
      ]
      expect(wire(nil, history).first).to eq(
        role: "assistant", content: "Hi!",
        "reasoning_details" => [{"type" => "reasoning.text", "text" => "t1", "signature" => "sig"}],
      )
    end

    it "reasoning_details wins over the raw field; an invalid array emits NOTHING (pi :1316-1347)" do
      details = '[{"type":"reasoning.text","text":"t1"}]'
      history = [assistant([{type: :thinking, thinking: "t", signature: details}, {type: :text, text: "x"}])]
      expect(wire(nil, history).first).to eq(
        role: "assistant", content: "x",
        "reasoning_details" => [{"type" => "reasoning.text", "text" => "t1"}],
      )

      # signature parses but is not a valid detail array AND is not a
      # reasoning field name → pi emits no reasoning field at all
      history = [assistant([{type: :thinking, thinking: "t", signature: "not json"}, {type: :text, text: "x"}])]
      expect(wire(nil, history).first).to eq({role: "assistant", content: "x"})

      # a FIELD-NAME signature with an invalid-JSON... a field name never
      # parses as details, so the raw field wins
      history = [assistant([{type: :thinking, thinking: "t", signature: "reasoning_content"}, {type: :text, text: "x"}])]
      expect(wire(nil, history).first).to eq({role: "assistant", content: "x", "reasoning_content" => "t"})
    end

    it "same-model thinking WITHOUT a reasoning-field signature emits NO reasoning field (pi :1344-1348)" do
      history = [assistant([{type: :thinking, thinking: "plain", signature: nil}, {type: :text, text: "x"}])]
      expect(wire(nil, history).first).to eq({role: "assistant", content: "x"})
    end

    it "cross-model thinking folds to a text block, concatenated (pi :113-130, fixture 10)" do
      history = [
        Fast::Completions::Message.user("hello"),
        assistant([{type: :thinking, thinking: "let me think", signature: "reasoning_content"},
                   {type: :text, text: "Hi!"}], provider: "other-provider"),
        Fast::Completions::Message.user("thanks"),
      ]
      expect(wire(nil, history)[1]).to eq({role: "assistant", content: "let me thinkHi!"})
    end

    it "redacted: same-model kept (replayed through its signature), cross-model dropped (pi :103-118)" do
      history = [assistant([
        {type: :thinking, thinking: "secret", signature: "reasoning_content", redacted: true},
        {type: :text, text: "x"},
      ])]
      expect(wire(nil, history).first).to eq({role: "assistant", content: "x", "reasoning_content" => "secret"})

      cross = [assistant([{type: :thinking, thinking: "secret", signature: "reasoning_content", redacted: true},
                          {type: :text, text: "x"}], provider: "other")]
      expect(wire(nil, cross).first).to eq({role: "assistant", content: "x"})
    end
  end

  describe "assistant wire shape (pi convertMessages :1348-1402)" do
    it "joins text to ONE plain string alongside tool_calls (pi :1351-1363)" do
      history = [assistant([{type: :text, text: "a"}, {type: :text, text: "b"},
                            {type: :tool_call, id: "c1", name: "read", arguments: {"path" => "x.rb"}}])]
      msg = wire(nil, history).first
      expect(msg).to eq(
        role: "assistant", content: "ab",
        tool_calls: [{id: "c1", type: "function", function: {name: "read", arguments: "{\"path\":\"x.rb\"}"}}],
      )
    end

    it "emits content:null for an assistant with tool_calls but no text (fixture 7)" do
      history = [assistant([{type: :tool_call, id: "c1", name: "read", arguments: {}}])]
      expect(wire(nil, history).first).to eq(
        role: "assistant", content: nil,
        tool_calls: [{id: "c1", type: "function", function: {name: "read", arguments: "{}"}}],
      )
    end

    it "skips EMPTY assistants (no text, no tool_calls — pi :1394-1402)" do
      history = [assistant([{type: :thinking, thinking: "", signature: nil}]), Fast::Completions::Message.user("u")]
      expect(wire(nil, history)).to eq([{role: "user", content: "u"}])
    end

    it "drops whitespace-only text parts from the join" do
      history = [assistant([{type: :text, text: "  "}, {type: :text, text: "real"}])]
      expect(wire(nil, history).first[:content]).to eq("real")
    end
  end

  describe "deepseek reasoning_content:\"\" (§9.5, pi :1387-1393)" do
    it "appends the empty reasoning_content on every assistant when required" do
      ds = Fast::Completions::Model.new(id: "mock-1", reasoning: true, context_window: 128_000,
        max_tokens: 512, provider: "mock", dialect: :deepseek)
      history = [Fast::Completions::Message.assistant([{type: :text, text: "x"}], provider: "mock",
        model: "mock-1", api: "openai-completions")]
      out = described_class.to_wire_messages(nil, described_class.normalize(history, ds), ds, ds.dialect)
      expect(out.first).to eq(role: "assistant", content: "x", "reasoning_content" => "")
    end

    it "does not clobber a real replayed reasoning_content" do
      ds = Fast::Completions::Model.new(id: "mock-1", reasoning: true, context_window: 128_000,
        max_tokens: 512, provider: "mock", dialect: :deepseek)
      history = [Fast::Completions::Message.assistant(
        [{type: :thinking, thinking: "deep", signature: "reasoning_content"}, {type: :text, text: "x"}],
        provider: "mock", model: "mock-1", api: "openai-completions")]
      out = described_class.to_wire_messages(nil, described_class.normalize(history, ds), ds, ds.dialect)
      expect(out.first["reasoning_content"]).to eq("deep")
    end
  end

  describe "orphaned tool calls (pi :158-180, OQ-8)" do
    it "inserts a synthetic error result after the assistant" do
      history = [
        assistant([{type: :tool_call, id: "c1", name: "read", arguments: {}}]),
        Fast::Completions::Message.user("thanks"),
      ]
      normalized = normalize(history)
      synth = normalized[1]
      expect(synth.tool_result?).to be(true)
      expect(synth.tool_call_id).to eq("c1")
      expect(synth.is_error).to be(true)
      expect(synth.content).to eq("No result provided")
      expect(synth.tool_name).to eq("read")
    end

    it "does not duplicate when the result already exists (across a held-back system message)" do
      history = [
        assistant([{type: :tool_call, id: "c1", name: "read", arguments: {}}]),
        Fast::Completions::Message.system("mid-convo note"),
        Fast::Completions::Message.tool_result(tool_call_id: "c1", content: "out"),
        Fast::Completions::Message.user("thanks"),
      ]
      normalized = normalize(history)
      expect(normalized.map(&:role)).to eq(%i[assistant tool_result system user]) # system held back past the result
    end

    it "synthesizes one result per unanswered call, then flushes held systems" do
      history = [
        assistant([{type: :tool_call, id: "c1", name: "a", arguments: {}},
                   {type: :tool_call, id: "c2", name: "b", arguments: {}}]),
        Fast::Completions::Message.system("held"),
        Fast::Completions::Message.user("thanks"),
      ]
      normalized = normalize(history)
      expect(normalized.map(&:role)).to eq(%i[assistant tool_result tool_result system user])
      expect(normalized[1].tool_call_id).to eq("c1")
      expect(normalized[2].tool_call_id).to eq("c2")
    end
  end

  describe "message conversion (§9.1)" do
    it "instructions: developer iff reasoning AND supports_developer_role (pi :1233)" do
      history = [Fast::Completions::Message.user("u")]
      expect(wire("be good", history).first).to eq(role: "developer", content: "be good")

      plain = Fast::Completions::Model.new(id: "mock-1", reasoning: false, context_window: 128_000, max_tokens: 512)
      out = described_class.to_wire_messages("be good", described_class.normalize(history, plain), plain, dialect)
      expect(out.first).to eq(role: "system", content: "be good")

      zai = Fast::Completions::Model.new(id: "mock-1", reasoning: true, context_window: 128_000,
        max_tokens: 512, dialect: :zai)
      out = described_class.to_wire_messages("be good", described_class.normalize(history, zai), zai, zai.dialect)
      expect(out.first).to eq(role: "system", content: "be good") # zai: no developer role
    end

    it "user strings pass verbatim; block arrays pass text parts; all-empty skips (pi :1319-1342)" do
      expect(wire(nil, [Fast::Completions::Message.user("hi")])).to eq([{role: "user", content: "hi"}])
      blocks = Fast::Completions::Message.user([{type: :text, text: "a"}, {type: :text, text: ""}])
      expect(wire(nil, [blocks])).to eq([{role: "user", content: [{type: "text", text: "a"}]}])
      empty = Fast::Completions::Message.user([{type: :text, text: ""}])
      expect(wire(nil, [empty])).to eq([])
    end

    it "tool results join text blocks with \\n; placeholder when empty; no name key" do
      msg = Fast::Completions::Message.tool_result(tool_call_id: "c1",
        content: [{type: :text, text: "line 1"}, {type: :text, text: "line 2"}])
      expect(wire(nil, [msg])).to eq([{role: "tool", content: "line 1\nline 2", tool_call_id: "c1"}])

      bare = Fast::Completions::Message.tool_result(tool_call_id: "c2", content: "")
      expect(wire(nil, [bare])).to eq([{role: "tool", content: "(no tool output)", tool_call_id: "c2"}])
    end
  end

  describe "outgoing-string scrub (I62 — pi sanitizeSurrogates)" do
    # The entry path is raw bytes (read/bash output, history text — Ruby
    # source escapes refuse surrogate literals), so the defect classes are
    # built with .pack("H*").force_encoding("UTF-8") per the frozen pins.
    def invalid_utf8(hex)
      [hex].pack("H*").force_encoding("UTF-8")
    end

    # Lone high surrogate, lone low surrogate, CESU-8 pair, invalid
    # non-surrogate bytes — Ruby's whole invalid-encoding class.
    def defect_classes
      @defect_classes ||= %w[eda0bd edb0a9 eda0bdedb8ba ff].map { |hex| invalid_utf8(hex) }
    end

    def strings_in(node, out = [])
      case node
      when String then out << node
      when Hash then node.each_value { |value| strings_in(value, out) }
      when Array then node.each { |value| strings_in(value, out) }
      end
      out
    end

    it "deletes every defect class at every scrubbed position; JSON.generate over the built request stays clean" do
      defect_classes.each do |bad|
        history = [
          Fast::Completions::Message.system("sys #{bad}"),
          Fast::Completions::Message.user("user #{bad}"),
          Fast::Completions::Message.user([{type: :text, text: "part #{bad}"}]),
          assistant([{type: :text, text: "text #{bad}"},
            {type: :thinking, thinking: "thinking #{bad}", signature: "reasoning_content"},
            {type: :thinking, thinking: "unsigned #{bad}"},
            {type: :tool_call, id: "c1", name: "read",
             arguments: {"path" => "arg #{bad}", "deep" => {"k" => ["nest #{bad}", 1, nil]}}}]),
          Fast::Completions::Message.tool_result(tool_call_id: "c1",
            content: [{type: :text, text: "result #{bad}"}]),
        ]
        params = wire("inst #{bad}", history)
        expect { JSON.generate(params) }.not_to raise_error
        strings_in(params).each do |str|
          expect(str.valid_encoding?).to be(true)
          expect(str).not_to include("\uFFFD") # DELETED, never replaced
        end
      end
    end

    it "carries pi's observable: the surrogate class is DELETED (\"Text \\u{D83D} here\" → \"Text  here\")" do
      defect_classes.each do |bad|
        expect(wire("Text #{bad} here", []).first[:content]).to eq("Text  here")
      end
    end

    it "scrubs each emission position exactly: system, user string/parts, assistant text, reasoning field, tool_result, arguments" do
      bad = defect_classes.first
      out = wire(nil, [
        Fast::Completions::Message.system("sys #{bad}"),
        Fast::Completions::Message.user("user #{bad}"),
        Fast::Completions::Message.user([{type: :text, text: "part #{bad}"}]),
        assistant([{type: :text, text: "text #{bad}"},
          {type: :thinking, thinking: "thinking #{bad}", signature: "reasoning_content"},
          {type: :tool_call, id: "c1", name: "read", arguments: {"path" => "arg #{bad}"}}]),
        Fast::Completions::Message.tool_result(tool_call_id: "c1",
          content: [{type: :text, text: "result #{bad}"}]),
      ])
      expect(out[0][:content]).to eq("sys ")
      expect(out[1][:content]).to eq("user ")
      expect(out[2][:content]).to eq([{type: "text", text: "part "}])
      expect(out[3][:content]).to eq("text ")
      expect(out[3]["reasoning_content"]).to eq("thinking ")
      expect(out[3][:tool_calls].first[:function][:arguments]).to eq('{"path":"arg "}')
      expect(out[4][:content]).to eq("result ")
    end

    it "passes valid strings BYTE-IDENTICAL — ASCII, multibyte, emoji" do
      text = "plain ascii, 中文 multibyte, 🙈 emoji — em-dash"
      out = wire(text, [
        Fast::Completions::Message.user(text),
        assistant([{type: :text, text: text},
          {type: :tool_call, id: "c1", name: "read", arguments: {"path" => text}}]),
        Fast::Completions::Message.tool_result(tool_call_id: "c1",
          content: [{type: :text, text: text}]),
      ])
      expect(out[0][:content]).to eq(text)
      expect(out[1][:content]).to eq(text)
      expect(out[2][:content]).to eq(text)
      expect(out[2]["reasoning_content"]).to be_nil # no thinking blocks
      expect(out[2][:tool_calls].first[:function][:arguments]).to eq(JSON.generate({"path" => text}))
      expect(out[3][:content]).to eq(text)
    end

    it "is a byte-identical no-op on every canonical fixture body string (parity's 11 bodies)" do
      fixture_dir = File.expand_path("../../fixtures/wire", __dir__)
      Dir.glob("#{fixture_dir}/*.json").sort.each do |path|
        body = JSON.parse(JSON.parse(File.read(path))["request_body"])
        strings_in(body).each do |str|
          expect(described_class.scrub_text(str).bytes).to eq(str.bytes)
        end
      end
    end
  end

  describe "stop_reason skip on replay (I62 — pi :196-206)" do
    it "round-trips: key absent when nil, present when set; the assistant factory accepts it; no vocabulary validation" do
      plain = assistant([{type: :text, text: "hi"}])
      expect(plain.stop_reason).to be_nil
      expect(plain.to_h.key?(:stop_reason)).to be(false)
      expect(Fast::Completions::Message.from_h(plain.to_h).stop_reason).to be_nil

      errored = assistant([{type: :text, text: "x"}], stop_reason: :error)
      expect(errored.stop_reason).to eq(:error)
      expect(errored.to_h[:stop_reason]).to eq(:error)
      expect(Fast::Completions::Message.from_h(errored.to_h).stop_reason).to eq(:error)

      custom = assistant([], stop_reason: :provider_weird)
      expect(custom.stop_reason).to eq(:provider_weird) # consumers carry their own
    end

    it "skips :error and :aborted assistants ENTIRELY — their tool calls never become pending orphans" do
      user = Fast::Completions::Message.user("go")
      errored = assistant([{type: :tool_call, id: "e1", name: "boom", arguments: {}}], stop_reason: :error)
      aborted = assistant([{type: :tool_call, id: "e2", name: "cut", arguments: {}}], stop_reason: :aborted)
      expect(normalize([user, errored, aborted]).map(&:role)).to eq(%i[user])
    end

    it "a PREVIOUS valid assistant's unanswered calls still synthesize; surrounding user/system messages unaffected" do
      valid = assistant([{type: :tool_call, id: "c1", name: "read", arguments: {"path" => "a"}}])
      errored = assistant([{type: :tool_call, id: "e1", name: "boom", arguments: {}}], stop_reason: :error)
      ctx = Fast::Completions::Message.system("ctx")
      out = normalize([valid, errored, ctx, Fast::Completions::Message.user("continue")])
      expect(out.map(&:role)).to eq(%i[assistant tool_result system user])
      expect(out[1].tool_call_id).to eq("c1") # the errored e1 never synthesizes
      expect(out[1].is_error).to be(true)
    end

    it "non-errored assistants pass through the transform carrying their stop_reason" do
      stopped = assistant([{type: :text, text: "done"}], stop_reason: :stop)
      out = normalize([stopped])
      expect(out.size).to eq(1)
      expect(out.first.stop_reason).to eq(:stop)
      expect(out.first.content).to eq([{type: :text, text: "done"}])
    end

    it "a history without errored rows is byte-identical to base (captured at 43ea169)" do
      history = [
        Fast::Completions::Message.user("go"),
        assistant([{type: :text, text: "reading"},
          {type: :tool_call, id: "c1", name: "read", arguments: {"path" => "a.rb"}}]),
        Fast::Completions::Message.tool_result(tool_call_id: "c1",
          content: [{type: :text, text: "contents"}]),
        assistant([{type: :text, text: "done"}]),
      ]
      expect(JSON.generate(normalize(history).map(&:to_h))).to eq(
        '[{"role":"user","content":"go"},{"role":"assistant","content":[{"type":"text","text":"reading"},{"type":"tool_call","id":"c1","name":"read","arguments":{"path":"a.rb"}}],"provider":"mock","model":"mock-1","api":"openai-completions"},{"role":"tool_result","content":[{"type":"text","text":"contents"}],"tool_call_id":"c1"},{"role":"assistant","content":[{"type":"text","text":"done"}],"provider":"mock","model":"mock-1","api":"openai-completions"}]'
      )
    end
  end

  describe "estimate (§9.6)" do
    it "ceils chars/3.5 over instruction + message texts" do
      msgs = [Fast::Completions::Message.user("1234567")] # 7 chars + instructions 0
      expect(described_class.estimate_tokens(nil, msgs)).to eq(2) # ceil(7/3.5)
      expect(described_class.estimate_tokens("ab", msgs)).to eq(3) # ceil(9/3.5)
    end
  end
end
