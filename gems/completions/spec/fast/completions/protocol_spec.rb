# frozen_string_literal: true

# Request build (THE BYTE CONTRACT, Specification §9 — pi buildParams
# openai-completions.ts :802-1000) and delta parse (§10 — pi stream
# :558-707). Byte-level parity with pi's recorded bodies is additionally
# pinned by the harness lane's wire_parity_spec (11 scenarios).
require "fast/completions"

RSpec.describe Fast::Completions::Protocol do
  def ladder_model(overrides = {})
    Fast::Completions::Model.new(
      id: "mock-1", reasoning: true, context_window: 128_000, max_tokens: 512,
      thinking_level_map: {off: "none", low: "low", medium: "medium", high: "high"},
      **overrides,
    )
  end

  def build(model, thinking: nil, messages: [], instructions: nil, tools: [], max_tokens: nil)
    described_class.build_request(
      model: model, messages: messages, instructions: instructions,
      tools: tools, thinking: thinking, max_tokens: max_tokens,
    )
  end

  describe "request build" do
    it "emits top-level keys in pi's insertion order (§9)" do
      hash = build(ladder_model, thinking: :high, instructions: "i", messages: [Fast::Completions::Message.user("u")])
      expect(hash.keys).to eq(%i[model messages stream stream_options store max_completion_tokens reasoning_effort])
      expect(hash[:model]).to eq("mock-1")
      expect(hash[:stream]).to be(true)
    end

    it "zai: no store (pi's zai suppression) while stream_options stays; max_tokens field (§9.4-9.6)" do
      model = ladder_model(dialect: :zai)
      hash = build(model, thinking: :high)
      expect(hash).not_to have_key(:store)
      expect(hash[:stream_options]).to eq(include_usage: true) # zai streams usage (fixture zai_on)
      expect(hash[:max_tokens]).to eq(512) # zai: maxTokensField max_tokens
      # a dialect CAN decline stream_options outright
      quiet = Fast::Completions.dialect(:quiet_spec) { supports_usage_in_streaming false }
      expect(build(ladder_model(dialect: quiet))).not_to have_key(:stream_options)
    end

    it "picks max_tokens vs max_completion_tokens per dialect and clamps to context (§9.6)" do
      roomy = ladder_model(max_tokens: 200_000)
      hash = build(roomy)
      expect(hash[:max_completion_tokens]).to eq(128_000 - 4_096) # no message text → estimate 0
      expect(build(ladder_model, max_tokens: 64)[:max_completion_tokens]).to eq(64)
      # the estimate narrows the room when the cap exceeds it
      big = ladder_model(max_tokens: 200_000)
      with_text = build(big, messages: [Fast::Completions::Message.user("1234567")]) # 7 chars → 2 tokens
      expect(with_text[:max_completion_tokens]).to eq(128_000 - 2 - 4_096)
    end

    it "clamps to the 1-token floor when the context cannot even fund the safety margin (§9.6)" do
      model = Fast::Completions::Model.new(id: "m", reasoning: false, context_window: 1_000, max_tokens: 50)
      expect(build(model)[:max_completion_tokens]).to eq(1) # max(1, 1000 − est − 4096) then min(50, …)
      tiny = Fast::Completions::Model.new(id: "m", reasoning: false, context_window: 128_000, max_tokens: 50)
      expect(build(tiny)[:max_completion_tokens]).to eq(50) # untouched when the window is roomy
    end

    it "converts tools to the function shape with VERBATIM parameters (§9.2)" do
      tool = Class.new(Fast::Completions::Tool) do
        tool_name "read"
        description "Read file contents."
        parameters do
          {"type" => "object", "required" => ["path"], "properties" => {"path" => {"type" => "string"}}}
        end
      end.new
      hash = build(ladder_model(reasoning: false), tools: [tool])
      expect(hash[:tools]).to eq([
        {"type" => "function", "function" => {
          "name" => "read", "description" => "Read file contents.",
          "parameters" => {"type" => "object", "required" => ["path"], "properties" => {"path" => {"type" => "string"}}},
        }},
      ])
      expect(hash[:tools].first["function"]["parameters"]).to equal(tool.parameters) # same object: verbatim
    end

    it "emits tools: [] when no tools but tool history exists (pi :860-863)" do
      history = [
        Fast::Completions::Message.assistant([{type: :tool_call, id: "c1", name: "t", arguments: {}}]),
        Fast::Completions::Message.tool_result(tool_call_id: "c1", content: "out"),
        Fast::Completions::Message.user("u"),
      ]
      expect(build(ladder_model(reasoning: false), messages: history)[:tools]).to eq([])
      expect(build(ladder_model(reasoning: false), messages: [Fast::Completions::Message.user("u")])).not_to have_key(:tools)
    end

    it "emits tool_stream only with the zai dialect AND tools (§9.8)" do
      tool = Class.new(Fast::Completions::Tool) { tool_name "t" }.new
      zai = build(ladder_model(dialect: :zai), tools: [tool])
      expect(zai.keys.index(:tools)).to be < zai.keys.index(:tool_stream)
      expect(zai[:tool_stream]).to be(true)
      expect(build(ladder_model, tools: [tool])).not_to have_key(:tool_stream)
    end

    describe "thinking arms (§9.9)" do
      it "zai: enabled+clear_thinking with effort, disabled without; effort map-else-level" do
        zai = ladder_model(thinking_level_map: {off: "disabled", high: "high"}, dialect: :zai)
        expect(build(zai, thinking: :high)[:thinking]).to eq({"type" => "enabled", "clear_thinking" => false})
        expect(build(zai, thinking: :high)[:reasoning_effort]).to eq("high")
        expect(build(zai, thinking: :off)[:thinking]).to eq({"type" => "disabled"})
        expect(build(zai, thinking: :off)).not_to have_key(:reasoning_effort)
        # unmapped level falls back to the level string
        raw_zai = ladder_model(dialect: :zai, thinking_level_map: nil)
        expect(build(raw_zai, thinking: :medium)[:reasoning_effort]).to eq("medium")
      end

      it "deepseek: enabled with effort; disabled without unless map.off is explicit nil (pi :928-937)" do
        ds = ladder_model(thinking_level_map: {off: "disabled", high: "high"}, dialect: :deepseek)
        expect(build(ds, thinking: :high)[:thinking]).to eq({"type" => "enabled"})
        expect(build(ds, thinking: :high)[:reasoning_effort]).to eq("high")
        # a map WITHOUT :off also emits disabled
        expect(build(ladder_model(thinking_level_map: {high: "high"}, dialect: :deepseek), thinking: nil)[:thinking])
          .to eq({"type" => "disabled"})
        # an explicit off: nil suppresses it
        quiet = ladder_model(thinking_level_map: {off: nil, high: "high"}, dialect: :deepseek)
        expect(build(quiet, thinking: nil)).not_to have_key(:thinking)
      end

      it "openai arm: effort map-else-level, and the off-floor (map.off string when no effort)" do
        expect(build(ladder_model, thinking: :high)[:reasoning_effort]).to eq("high")
        expect(build(ladder_model, thinking: :off)[:reasoning_effort]).to eq("none") # NOT omitted: the off-floor
        no_off = ladder_model(thinking_level_map: {high: "high"})
        expect(build(no_off, thinking: :high)[:reasoning_effort]).to eq("high")
        expect(build(no_off, thinking: nil)).not_to have_key(:reasoning_effort)
      end

      it "model.reasoning gates EVERY arm (a non-reasoning model emits none)" do
        plain = ladder_model(reasoning: false)
        expect(build(plain, thinking: :high)).not_to have_key(:reasoning_effort)
        zai = ladder_model(reasoning: false, dialect: :zai)
        expect(build(zai, thinking: :high)).not_to have_key(:thinking)
      end
    end

    describe "thinking budget (§9.10, pi simple-options.ts :66-101)" do
      it "clamps the level budget to max − 1024 and emits after the effort arm" do
        model = ladder_model(
          max_tokens: 4096,
          thinking_level_map: {off: "none", high: "high"},
          dialect: Fast::Completions.dialect(:budget_spec) { thinking_token_budget_field "thinking_token_budget" },
        )
        hash = build(model, thinking: :high)
        expect(hash.keys).to end_with(:reasoning_effort, :thinking_token_budget)
        expect(hash[:thinking_token_budget]).to eq(3072) # min(16384, 4096−1024)
      end

      it "xhigh/max clamp to high's budget (pi clampReasoning)" do
        model = ladder_model(
          max_tokens: 4096,
          thinking_level_map: {high: "high", xhigh: "xhigh", max: "max"},
          dialect: Fast::Completions.dialect(:budget_spec2) { thinking_token_budget_field "thinking_token_budget" },
        )
        expect(build(model, thinking: :xhigh)[:thinking_token_budget]).to eq(3072)
      end

      it "supports_thinking_token_budget implies the thinking_token_budget field" do
        dialect = Fast::Completions.dialect(:budget_spec3) { supports_thinking_token_budget true }
        model = ladder_model(max_tokens: 4096, dialect: dialect, thinking_level_map: {high: "high"})
        expect(build(model, thinking: :high)[:thinking_token_budget]).to eq(3072)
      end

      it "omits the key when the clamped budget is 0 (pi :1021-1022)" do
        dialect = Fast::Completions.dialect(:budget_spec4) { thinking_token_budget_field "thinking_token_budget" }
        model = ladder_model(max_tokens: 1024, dialect: dialect, thinking_level_map: {high: "high"})
        expect(build(model, thinking: :high)).not_to have_key(:thinking_token_budget)
      end
    end
  end

  describe "delta parse" do
    let(:dialect) { Fast::Completions::Dialect.new(nil) }
    let(:model) { ladder_model }

    def accumulator
      described_class::StreamAccumulator.new(model, dialect)
    end

    def chunk(delta, extra = {})
      {"choices" => [{"delta" => delta}]}.merge(extra)
    end

    it "captures response_id (first wins) and a differing response_model (§10.1)" do
      acc = accumulator
      acc.consume({"id" => "resp-1", "choices" => []})
      acc.consume({"id" => "resp-2", "model" => "other", "choices" => []})
      expect(acc.partial.response_id).to eq("resp-1")
      expect(acc.partial.response_model).to eq("other")
    end

    it "reasoning fields: FIRST non-empty wins, field name becomes the signature (pi :616-641)" do
      acc = accumulator
      events = acc.consume(chunk({"reasoning_content" => "", "reasoning" => "real"}))
      expect(events.map(&:type)).to eq(%i[thinking_start thinking_delta])
      expect(events.last.delta).to eq("real")
      acc.consume(chunk({"reasoning" => "more"}))
      events, = acc.finish
      block = acc.partial.content.first
      expect(block[:signature]).to eq("reasoning")
      expect(block[:thinking]).to eq("realmore")
      expect(events.first.type).to eq(:thinking_end)
    end

    it "text blocks: one start, deltas append, end carries the full content" do
      acc = accumulator
      events = acc.consume(chunk({"content" => "Hel"}))
      events.concat(acc.consume(chunk({"content" => "lo"})))
      expect(events.map(&:type)).to eq(%i[text_start text_delta text_delta])
      end_events, = acc.finish
      expect(end_events.first.type).to eq(:text_end)
      expect(end_events.first.content).to eq("Hello")
      expect(acc.partial.content.first[:text]).to eq("Hello")
    end

    it "tool calls accumulate by index-then-id with RAW string deltas (pi :643-662)" do
      acc = accumulator
      events = acc.consume(chunk({"tool_calls" => [
        {"index" => 0, "id" => "c1", "function" => {"name" => "read", "arguments" => ""}},
      ]}))
      expect(events.map(&:type)).to eq(%i[tool_call_start tool_call_delta])
      # same index: same block; the delta carries the RAW string
      events = acc.consume(chunk({"tool_calls" => [
        {"index" => 0, "function" => {"arguments" => "{\"path\":\"a.rb\""}},
      ]}))
      expect(events.last.delta).to eq("{\"path\":\"a.rb\"")
      # a SECOND index creates a second block
      events = acc.consume(chunk({"tool_calls" => [
        {"index" => 1, "id" => "c2", "function" => {"name" => "write", "arguments" => ""}},
      ]}))
      expect(events.first.type).to eq(:tool_call_start)
      # a no-index entry with a KNOWN id attaches to its block; the
      # continuation completes the JSON (OQ-4: repair + {} last resort —
      # pi's partial-json prefix parse is NOT ported, Specification §14/OQ-4)
      acc.consume(chunk({"tool_calls" => [
        {"id" => "c1", "function" => {"arguments" => "}"}},
      ]}))
      acc.consume({"choices" => [{"delta" => {}, "finish_reason" => "tool_calls"}]})
      end_events, outcome = acc.finish
      expect(outcome).to eq([:done, :tool_use])
      tool_calls = acc.partial.content.select { |b| b[:type] == :tool_call }
      expect(tool_calls.size).to eq(2)
      expect(tool_calls.first[:arguments]).to eq({"path" => "a.rb"})
      ids = end_events.select { |e| e.type == :tool_call_end }.map { |e| e.tool_call[:id] }
      expect(ids).to eq(%w[c1 c2])
    end

    it "id backfills onto an empty-id block (pi :666-668)" do
      acc = accumulator
      acc.consume(chunk({"tool_calls" => [{"index" => 0, "function" => {"name" => "x", "arguments" => ""}}]}))
      acc.consume(chunk({"tool_calls" => [{"index" => 0, "id" => "late", "function" => {"arguments" => "{}"}}]}))
      block = acc.partial.content.first
      expect(block[:id]).to eq("late")
    end

    describe "index-map backfill (I62 — pi :536-539)" do
      # The frozen R1 shape (Grounds R1): an id-carrying index-less opener,
      # then the SAME id carrying the index (found-by-id → backfill), then
      # bare index-routed continuations. At base this mis-assembles into a
      # spurious second block — the id-only opener never entered the map.
      it "backfills the index map on a found-by-id fragment: ONE block, arguments across frag2+frag3, natural :tool_use" do
        acc = accumulator
        acc.consume(chunk({"tool_calls" => [
          {"id" => "c1", "function" => {"name" => "read", "arguments" => ""}},
        ]}))
        acc.consume(chunk({"tool_calls" => [
          {"id" => "c1", "index" => 0, "function" => {"arguments" => "{\"path\":\"a.rb\""}},
        ]}))
        acc.consume(chunk({"tool_calls" => [
          {"index" => 0, "function" => {"arguments" => ",\"mode\":\"r\"}"}},
        ]}))
        acc.consume({"choices" => [{"delta" => {}, "finish_reason" => "tool_calls"}]})
        _, outcome = acc.finish
        expect(outcome).to eq([:done, :tool_use])
        calls = acc.partial.content.select { |b| b[:type] == :tool_call }
        expect(calls.size).to eq(1)
        expect(calls.first[:id]).to eq("c1")
        expect(calls.first[:arguments]).to eq({"path" => "a.rb", "mode" => "r"})
      end

      it "first index wins: a later same-id fragment with a DIFFERENT index does not rebind" do
        acc = accumulator
        acc.consume(chunk({"tool_calls" => [
          {"id" => "c1", "function" => {"name" => "read", "arguments" => ""}},
        ]}))
        acc.consume(chunk({"tool_calls" => [
          {"id" => "c1", "index" => 0, "function" => {"arguments" => "{\"path\":\"a.rb\"}"}},
        ]}))
        # Same id, different index: the block stays bound to index 0 —
        # so a subsequent bare index-5 fragment opens a FRESH block
        # (pi parity), proving index 5 was never routed to the block.
        acc.consume(chunk({"tool_calls" => [
          {"id" => "c1", "index" => 5, "function" => {"arguments" => ""}},
        ]}))
        acc.consume(chunk({"tool_calls" => [
          {"index" => 5, "function" => {"arguments" => "{\"x\":1}"}},
        ]}))
        acc.consume({"choices" => [{"delta" => {}, "finish_reason" => "tool_calls"}]})
        acc.finish
        calls = acc.partial.content.select { |b| b[:type] == :tool_call }
        expect(calls.size).to eq(2)
        expect(calls.first[:arguments]).to eq({"path" => "a.rb"})
        expect(calls.last[:arguments]).to eq({"x" => 1})
      end

      it "binds without leaking scratch keys onto the emitted message blocks" do
        acc = accumulator
        acc.consume(chunk({"tool_calls" => [
          {"id" => "c1", "function" => {"name" => "read", "arguments" => ""}},
        ]}))
        acc.consume(chunk({"tool_calls" => [
          {"id" => "c1", "index" => 0, "function" => {"arguments" => "{}"}},
        ]}))
        end_events, = acc.finish
        expect(acc.partial.content.first.keys).to contain_exactly(:type, :id, :name, :arguments)
        end_events.select { |e| e.type == :tool_call_end }.each do |event|
          expect(event.tool_call.keys).to contain_exactly(:id, :name, :arguments)
        end
      end
    end

    it "live-parses partial arguments best-effort and repairs control chars at finalize (OQ-4)" do
      acc = accumulator
      acc.consume(chunk({"tool_calls" => [
        {"index" => 0, "id" => "c1", "function" => {"name" => "t", "arguments" => "{\"path\":\"li"}},
      ]}))
      block = acc.partial.content.first
      expect(block[:arguments]).to eq({}) # truncated → best-effort {}
      acc.consume(chunk({"tool_calls" => [
        {"index" => 0, "function" => {"arguments" => "ne1\r\nline\t2\"}"}},
      ]}))
      # repairJson escapes the RAW control characters for the parser; the
      # parsed arguments carry the literal \r and \n characters back.
      expect(block[:arguments]).to eq({"path" => "line1\r\nline\t2"})
    end

    it "reasoning_details deltas accumulate with consecutive merge and serialize at finalize (pi :334-341, :664-677)" do
      acc = accumulator
      details = [
        {"type" => "reasoning.text", "text" => "t1", "signature" => "s"},
        {"type" => "reasoning.text", "text" => "t2"},
        {"type" => "reasoning.encrypted", "data" => "D"},
      ]
      acc.consume(chunk({"reasoning_details" => details}))
      expect(acc.partial.content.first[:type]).to eq(:thinking)
      end_events, = acc.finish
      block = acc.partial.content.first
      expect(JSON.parse(block[:signature])).to eq([
        {"type" => "reasoning.text", "text" => "t1t2", "signature" => "s"},
        {"type" => "reasoning.encrypted", "data" => "D"},
      ])
    end

    it "invalid reasoning_details entries are skipped (pi isOpenAIReasoningDetail :135-165)" do
      acc = accumulator
      acc.consume(chunk({"reasoning_details" => [
        {"type" => "reasoning.summary"},                       # no summary → invalid
        {"type" => "reasoning.summary", "summary" => "ok"},    # valid
        "not even an object",
      ]}))
      acc.consume(chunk({"reasoning_details" => [
        {"type" => "mystery", "data" => "x"},
      ]}))
      _, outcome = acc.finish
      block = acc.partial.content.first
      expect(JSON.parse(block[:signature])).to eq([{"type" => "reasoning.summary", "summary" => "ok"}])
    end

    describe "usage (§10.1, pi parseChunkUsage :1519-1547)" do
      def usage_of(chunk)
        acc = accumulator
        acc.consume(chunk)
        acc.partial.usage
      end

      it "computes pi's formula with native total_tokens (OQ-9)" do
        usage = usage_of({"usage" => {"prompt_tokens" => 100, "completion_tokens" => 30,
                                      "prompt_tokens_details" => {"cached_tokens" => 20, "cache_write_tokens" => 5},
                                      "completion_tokens_details" => {"reasoning_tokens" => 10}}})
        expect(usage.to_h).to eq(input: 75, output: 30, cache_read: 20, cache_write: 5, reasoning: 10, total_tokens: 130)
      end

      it "falls back prompt_cache_hit_tokens (deepseek) then cached_tokens (kimi)" do
        expect(usage_of({"usage" => {"prompt_tokens" => 50, "prompt_cache_hit_tokens" => 11}}).cache_read).to eq(11)
        expect(usage_of({"usage" => {"prompt_tokens" => 50, "cached_tokens" => 7}}).cache_read).to eq(7)
      end

      it "falls back to choice.usage when chunk.usage is absent (Moonshot, pi :582-585)" do
        usage = usage_of({"choices" => [{"delta" => {}, "usage" => {"prompt_tokens" => 9, "completion_tokens" => 1}}]})
        expect(usage.total_tokens).to eq(10)
      end

      it "input never goes negative and missing fields default to 0" do
        usage = usage_of({"usage" => {"prompt_tokens" => 3, "prompt_tokens_details" => {"cached_tokens" => 10}}})
        expect(usage.input).to eq(0)
        expect(usage.output).to eq(0)
      end
    end

    describe "stop reasons (§10.2, pi mapStopReason :1562-1589)" do
      def stop_for(raw)
        acc = accumulator
        acc.consume({"choices" => [{"delta" => {}, "finish_reason" => raw}]})
        _, outcome = acc.finish
        outcome
      end

      it "maps the frozen table" do
        expect(stop_for("stop")).to eq([:done, :stop])
        expect(stop_for("end")).to eq([:done, :stop])
        expect(stop_for("length")).to eq([:done, :length])
        expect(stop_for("tool_calls")).to eq([:done, :tool_use])
        expect(stop_for("function_call")).to eq([:done, :tool_use])
      end

      it "maps unknown/content_filter/network_error to the error discipline" do
        expect(stop_for("content_filter")).to eq([:stream_error, "Provider finish_reason: content_filter"])
        expect(stop_for("network_error")).to eq([:stream_error, "Provider finish_reason: network_error"])
        expect(stop_for("weird")).to eq([:stream_error, "Provider finish_reason: weird"])
      end
    end

    describe "terminal discipline (§10.5)" do
      it "infers tool_use/stop when no finish_reason and the dialect supports none (pi :690-692)" do
        no_finish = Fast::Completions::Dialect.new(nil, supports_finish_reason: false)
        acc = described_class::StreamAccumulator.new(model, no_finish)
        acc.consume(chunk({"content" => "hi"}))
        _, outcome = acc.finish
        expect(outcome).to eq([:done, :stop])

        acc = described_class::StreamAccumulator.new(model, no_finish)
        acc.consume(chunk({"tool_calls" => [{"index" => 0, "id" => "c", "function" => {"name" => "t", "arguments" => "{}"}}]}))
        _, outcome = acc.finish
        expect(outcome).to eq([:done, :tool_use])
      end

      it "raises StreamError semantics when finish_reason is expected but absent" do
        acc = accumulator
        acc.consume(chunk({"content" => "hi"}))
        _, outcome = acc.finish
        expect(outcome).to eq([:stream_error, "Stream ended without finish_reason"])
      end

      it ":start precedes every block event and events carry the shared partial (§10.6, §3)" do
        acc = accumulator
        start = acc.start_event
        events = acc.consume(chunk({"content" => "x"}))
        expect(events.first.partial).to equal(acc.partial)
        expect(start.type).to eq(:start)
      end
    end
  end
end
