# frozen_string_literal: true

# Dialect declaration pins (Specification §4): the closed 15-key
# vocabulary, defaults = the plain arm, the well-known trio, fail-loud
# validation, last-declaration-wins.
require "fast/completions"

RSpec.describe Fast::Completions::Dialect do
  it "defaults to the plain arm (thinking_format :openai)" do
    dialect = described_class.new(nil)
    expect(dialect.thinking_format).to eq(:openai)
    expect(dialect.max_tokens_field).to eq("max_completion_tokens")
    expect(dialect.supports_developer_role).to be(false) # v1.6.0 #10741: the developer role is OpenAI's (openai-completions.js:1259-1265 + :890)
    expect(dialect.supports_reasoning_effort).to be(true)
    expect(dialect.supports_store).to be(true)
    expect(dialect.supports_usage_in_streaming).to be(true)
    expect(dialect.supports_finish_reason).to be(true)
    expect(dialect.requires_reasoning_content_on_assistant_messages).to be(false)
    expect(dialect.zai_tool_stream).to be(false)
    expect(dialect.thinking_token_budget_field).to be_nil
    expect(dialect.supports_thinking_token_budget).to be(false)
    expect(dialect.send_session_affinity_headers).to be(false)
    expect(dialect.session_affinity_format).to eq(:openai)
    expect(dialect.supports_strict_mode).to be(false)
    expect(dialect.requires_tools_with_tool_history).to be(false) # v1.6.0 #11843 (openai-completions.js:595-597 + detected :1273)
  end

  it "has a CLOSED 15-key vocabulary; unknown keys raise ArgumentError at declaration" do
    expect { described_class.new(nil, no_such_key: true) }
      .to raise_error(ArgumentError, /unknown dialect key :no_such_key/)
  end

  it "raises ArgumentError on unknown enum values (§4: ANY OTHER VALUE RAISES)" do
    expect { described_class.new(nil, thinking_format: :qwen) }.to raise_error(ArgumentError, /thinking_format/)
    expect { described_class.new(nil, max_tokens_field: "max_output_tokens") }.to raise_error(ArgumentError, /max_tokens_field/)
    expect { described_class.new(nil, session_affinity_format: :weird) }.to raise_error(ArgumentError, /session_affinity_format/)
    expect { described_class.new(nil, thinking_token_budget_field: "tokens_please") }.to raise_error(ArgumentError, /thinking_token_budget_field/)
  end

  it "is a value object: == by keys, to_h declaration-order-stable" do
    a = described_class.new(:a, thinking_format: :zai, supports_store: false)
    b = described_class.new(:b, supports_store: false, thinking_format: :zai)
    expect(a).to eq(b) # same values, different declaration order
    expect(a.to_h.keys).to eq(described_class::VOCABULARY.keys)
    expect(a.to_h[:thinking_format]).to eq(:zai)
  end

  it "reads each declared key (declared through the DSL)" do
    dialect = Fast::Completions.dialect(:dsl_probe) do
      thinking_format :deepseek
      zai_tool_stream true
    end
    expect(dialect.thinking_format).to eq(:deepseek)
    expect(dialect.zai_tool_stream).to be(true)
    expect(dialect.name).to eq(:dsl_probe)
  end
end

RSpec.describe Fast::Completions.dialect(:zai) do
  it "is the I46 five-key subset + pi's zai store suppression + strict mode (§4)" do
    expect(subject.thinking_format).to eq(:zai)
    expect(subject.zai_tool_stream).to be(true)
    expect(subject.max_tokens_field).to eq("max_tokens")
    expect(subject.supports_developer_role).to be(false)
    expect(subject.supports_reasoning_effort).to be(true)
    expect(subject.supports_store).to be(false)
    expect(subject.supports_strict_mode).to be(true)
  end
end

RSpec.describe "supports_strict_mode (I63 — the 14th key at its landing; the 15th is requires_tools_with_tool_history)" do
  it "supports_strict_mode defaults false, is a free boolean, and sits second-to-last in canonical order" do
    expect(Fast::Completions::Dialect::VOCABULARY[:supports_strict_mode]).to eq([false, nil])
    expect(Fast::Completions::Dialect::VOCABULARY.size).to eq(15)
    dialect = Fast::Completions::Dialect.new(nil)
    expect(dialect.supports_strict_mode).to be(false)
    expect(dialect.to_h.keys.last).to eq(:requires_tools_with_tool_history) # the 15th key appended after supports_strict_mode
    expect(dialect.to_h.keys[-2]).to eq(:supports_strict_mode) # appended after session_affinity_format
    expect(Fast::Completions::Dialect.new(nil, supports_strict_mode: true).supports_strict_mode).to be(true)
  end

  it ":zai declares supports_strict_mode true (pi zai.json glm compat); :deepseek, :fireworks, and the default are false" do
    expect(Fast::Completions.dialect(:zai).supports_strict_mode).to be(true)
    expect(Fast::Completions.dialect(:deepseek).supports_strict_mode).to be(false)
    expect(Fast::Completions.dialect(:fireworks).supports_strict_mode).to be(false)
    expect(Fast::Completions::Dialects.default.supports_strict_mode).to be(false)
  end

  it "supports_strict_mode is INSIDE the closed vocabulary — unknown keys still raise ArgumentError at declaration" do
    expect { Fast::Completions::Dialect.new(nil, no_such_key: true) }
      .to raise_error(ArgumentError, /unknown dialect key :no_such_key/)
  end
end

RSpec.describe "the v1.6.0 default flips (#10741 + #11843)" do
  it "supports_developer_role defaults FALSE (pi openai-completions.js:1259-1265 supportsDeveloperRole = isOpenAI + :890 instructionRole); an explicit true declaration still opts in (pi's own API hosts)" do
    expect(Fast::Completions::Dialect::VOCABULARY[:supports_developer_role]).to eq([false, nil])
    expect(Fast::Completions::Dialects.default.supports_developer_role).to be(false)
    expect(Fast::Completions.dialect(:openai_host_probe) { supports_developer_role true }.supports_developer_role).to be(true)
  end

  it "requires_tools_with_tool_history defaults false, is a free boolean, and sits LAST in canonical order (pi openai-completions.js:595-597 + detected :1273)" do
    expect(Fast::Completions::Dialect::VOCABULARY[:requires_tools_with_tool_history]).to eq([false, nil])
    expect(Fast::Completions::Dialect.new(nil).requires_tools_with_tool_history).to be(false)
    expect(Fast::Completions::Dialect.new(nil).to_h.keys.last).to eq(:requires_tools_with_tool_history)
    expect(Fast::Completions.dialect(:tools_on_history_probe) { requires_tools_with_tool_history true }.requires_tools_with_tool_history).to be(true)
  end
end

RSpec.describe "the well-known trio" do
  it "ships :deepseek per pi's detection" do
    ds = Fast::Completions.dialect(:deepseek)
    expect(ds.thinking_format).to eq(:deepseek)
    expect(ds.max_tokens_field).to eq("max_tokens")
    expect(ds.supports_developer_role).to be(false)
    expect(ds.requires_reasoning_content_on_assistant_messages).to be(true)
    expect(ds.supports_store).to be(false)
  end

  it "ships :fireworks as the empty declaration (every default)" do
    expect(Fast::Completions.dialect(:fireworks)).to eq(Fast::Completions::Dialect.new(nil))
  end

  it "looks up by name, raising KeyError when undeclared (§3)" do
    expect(Fast::Completions.dialect(:zai)).to be_a(Fast::Completions::Dialect)
    expect { Fast::Completions.dialect(:never_declared) }.to raise_error(KeyError, /never_declared/)
  end

  it "re-declaring overrides — last declaration wins (§4, documented)" do
    custom = Fast::Completions.dialect(:override_probe) { supports_store false }
    again = Fast::Completions.dialect(:override_probe) { supports_store true }
    expect(again.supports_store).to be(true)
    expect(again).not_to eq(custom)
    expect(Fast::Completions.dialects).to be_frozen
    expect(Fast::Completions.dialects[:override_probe]).to eq(again)
  end
end
