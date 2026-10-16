# frozen_string_literal: true

# Constrained-sampling engine pins (I63, D6/AC3): the rewrite + resolution
# semantics ported from pi api/constrained-sampling.ts @ f1b2e77f5. Message
# bytes are pi's literals verbatim; check order = throw order.
require "fast/completions"

RSpec.describe Fast::Completions::ConstrainedSampling do
  # The §12.3-shaped declared schema: `offset` is the optional non-null
  # property pi's rewrite must wrap.
  DECLARED = {
    "type" => "object",
    "required" => ["path"],
    "properties" => {
      "path" => {"type" => "string"},
      "offset" => {"type" => "number"},
    },
  }.freeze

  def sampling_tool(config, schema: DECLARED)
    Class.new(Fast::Completions::Tool) do
      tool_name "read"
      parameters schema
      constrained_sampling config unless config == :absent
    end.new
  end

  # A Hash whose traversal raises — the stand-in for any non-Unsupported
  # error escaping the rewrite (pi's structuredClone DataCloneError and
  # isUnsupportedKeyword rethrows). Only UnsupportedStrictJsonSchemaError
  # may be caught by the resolver.
  BOMB = Class.new(Hash) do
    def each(*) = raise(RuntimeError, "provider keyword hook exploded")
  end.new.merge("type" => "object").freeze

  describe "make_strict_json_schema — the rewrite" do
    it "rewrites a nested schema: required kept in position, nested objects, arrays via items, anyOf passthrough, enum/const null allowance" do
      schema = {
        "type" => "object",
        "required" => ["id"],
        "properties" => {
          "id" => {"type" => "string"},
          "meta" => {
            "type" => "object",
            "properties" => {"tag" => {"type" => "string"}, "score" => {"type" => "number"}},
          },
          "tags" => {"type" => "array", "items" => {"type" => "string"}},
          "mode" => {"anyOf" => [{"type" => "string"}, {"type" => "null"}]},
          "note" => {"type" => "string", "const" => nil},
          "level" => {"enum" => ["low", "high", nil]},
        },
      }
      out = described_class.make_strict_json_schema(schema)
      # every property required; optional non-null-less wrapped anyOf-with-null
      expect(out["required"]).to eq(["id", "meta", "tags", "mode", "note", "level"])
      # key position preserved: required where declared, additionalProperties appended
      expect(out.keys).to eq(["type", "required", "properties", "additionalProperties"])
      expect(out["additionalProperties"]).to be(false)
      # optional nested object: recursed AND wrapped (it doesn't allow null) — assert through the wrapper
      meta = out["properties"]["meta"]["anyOf"][0]
      expect(meta["required"]).to eq(["tag", "score"])
      expect(meta.keys).to eq(["type", "properties", "required", "additionalProperties"])
      expect(meta["additionalProperties"]).to be(false)
      expect(out["properties"]["tags"]["anyOf"][0]["items"]).to eq("type" => "string") # optional non-null-allowing array: wrapped; non-tuple items recursed, untouched
      # already-null-allowing optionals pass through UNwrapped
      expect(out["properties"]["mode"]).to eq("anyOf" => [{"type" => "string"}, {"type" => "null"}])
      expect(out["properties"]["note"]).to eq("type" => "string", "const" => nil)
      expect(out["properties"]["level"]).to eq("enum" => ["low", "high", nil])
    end

    it "wraps an optional non-null-allowing property in anyOf-with-null, keeping its key position" do
      out = described_class.make_strict_json_schema(DECLARED)
      expect(out["properties"].keys).to eq(["path", "offset"])
      expect(out["properties"]["offset"]).to eq("anyOf" => [{"type" => "number"}, {"type" => "null"}])
      expect(out["properties"]["path"]).to eq("type" => "string")
      expect(out["required"]).to eq(["path", "offset"])
    end

    it "throws 'boolean schemas are unsupported' on every non-object node (nested arm)" do
      [true, false, nil, [], "string", 42, 4.2].each do |node|
        expect {
          described_class.make_strict_json_schema({"type" => "object", "properties" => {"x" => node}})
        }.to raise_error(Fast::Completions::UnsupportedStrictJsonSchemaError, "boolean schemas are unsupported")
      end
    end

    it "throws '<key> schemas are unsupported' for each of pi's 16 frozen keys, first present key in list order" do
      expect(described_class::UNSUPPORTED_STRICT_SCHEMA_KEYS).to eq(
        %w[$ref $defs definitions allOf oneOf patternProperties dependentSchemas dependencies
           unevaluatedProperties propertyNames contains prefixItems not if then else]
      )
      described_class::UNSUPPORTED_STRICT_SCHEMA_KEYS.each do |key|
        expect {
          described_class.make_strict_json_schema({"type" => "object", "properties" => {"x" => {key => {}}}})
        }.to raise_error(Fast::Completions::UnsupportedStrictJsonSchemaError, "#{key} schemas are unsupported")
      end
      # list order wins over hash order: $ref precedes not
      expect {
        described_class.make_strict_json_schema({"type" => "object", "properties" => {"x" => {"not" => {}, "$ref" => {}}}})
      }.to raise_error(Fast::Completions::UnsupportedStrictJsonSchemaError, "$ref schemas are unsupported")
    end

    it "throws on empty/non-array anyOf and on structured union variants (type, properties, items arms)" do
      expect {
        described_class.make_strict_json_schema({"type" => "object", "properties" => {"x" => {"anyOf" => []}}})
      }.to raise_error(Fast::Completions::UnsupportedStrictJsonSchemaError, "anyOf must contain at least one schema")
      expect {
        described_class.make_strict_json_schema({"type" => "object", "properties" => {"x" => {"anyOf" => {"type" => "string"}}}})
      }.to raise_error(Fast::Completions::UnsupportedStrictJsonSchemaError, "anyOf must contain at least one schema")
      expect {
        described_class.make_strict_json_schema({"type" => "object", "properties" => {"x" => {"anyOf" => [{"type" => "object"}]}}})
      }.to raise_error(Fast::Completions::UnsupportedStrictJsonSchemaError, "object and array unions are unsupported")
      expect {
        described_class.make_strict_json_schema({"type" => "object", "properties" => {"x" => {"anyOf" => [{"properties" => {}}]}}})
      }.to raise_error(Fast::Completions::UnsupportedStrictJsonSchemaError, "object and array unions are unsupported")
      expect {
        described_class.make_strict_json_schema({"type" => "object", "properties" => {"x" => {"anyOf" => [{"items" => {"type" => "string"}}]}}})
      }.to raise_error(Fast::Completions::UnsupportedStrictJsonSchemaError, "object and array unions are unsupported")
    end

    it "throws 'tuple schemas are unsupported' on array items — and recurses into non-tuple items" do
      expect {
        described_class.make_strict_json_schema({"type" => "object", "properties" => {"x" => {"type" => "array", "items" => [{"type" => "string"}]}}})
      }.to raise_error(Fast::Completions::UnsupportedStrictJsonSchemaError, "tuple schemas are unsupported")
      expect {
        described_class.make_strict_json_schema({"type" => "object", "properties" => {"x" => {"type" => "array", "items" => {"$ref" => "#"}}}})
      }.to raise_error(Fast::Completions::UnsupportedStrictJsonSchemaError, "$ref schemas are unsupported")
    end

    it "throws 'properties require type object' on properties without the object type" do
      expect {
        described_class.make_strict_json_schema({"properties" => {"x" => {"type" => "string"}}})
      }.to raise_error(Fast::Completions::UnsupportedStrictJsonSchemaError, "properties require type object")
      expect {
        described_class.make_strict_json_schema({"type" => "object", "properties" => {"x" => {"type" => "string", "properties" => {"y" => {"type" => "string"}}}}})
      }.to raise_error(Fast::Completions::UnsupportedStrictJsonSchemaError, "properties require type object")
    end

    it "throws 'schema-valued or true additionalProperties is unsupported' (true and schema-valued arms)" do
      expect {
        described_class.make_strict_json_schema({"type" => "object", "properties" => {}, "additionalProperties" => true})
      }.to raise_error(Fast::Completions::UnsupportedStrictJsonSchemaError, "schema-valued or true additionalProperties is unsupported")
      expect {
        described_class.make_strict_json_schema({"type" => "object", "properties" => {}, "additionalProperties" => {"type" => "string"}})
      }.to raise_error(Fast::Completions::UnsupportedStrictJsonSchemaError, "schema-valued or true additionalProperties is unsupported")
    end

    it "throws 'object properties must be a schema map' on non-Hash properties" do
      expect {
        described_class.make_strict_json_schema({"type" => "object", "properties" => []})
      }.to raise_error(Fast::Completions::UnsupportedStrictJsonSchemaError, "object properties must be a schema map")
    end

    it "throws 'object required must be a string array' on non-array and non-string-entry required" do
      expect {
        described_class.make_strict_json_schema({"type" => "object", "properties" => {}, "required" => "path"})
      }.to raise_error(Fast::Completions::UnsupportedStrictJsonSchemaError, "object required must be a string array")
      expect {
        described_class.make_strict_json_schema({"type" => "object", "properties" => {}, "required" => ["path", 4]})
      }.to raise_error(Fast::Completions::UnsupportedStrictJsonSchemaError, "object required must be a string array")
    end

    it "throws 'required contains an unknown property' when required names no property" do
      expect {
        described_class.make_strict_json_schema({"type" => "object", "properties" => {"path" => {"type" => "string"}}, "required" => ["path", "offset"]})
      }.to raise_error(Fast::Completions::UnsupportedStrictJsonSchemaError, "required contains an unknown property")
    end

    it "throws 'root schema must have type object' on BOTH root arms: non-Hash root and non-object-typed root" do
      expect { described_class.make_strict_json_schema([]) }
        .to raise_error(Fast::Completions::UnsupportedStrictJsonSchemaError, "root schema must have type object")
      expect { described_class.make_strict_json_schema(nil) }
        .to raise_error(Fast::Completions::UnsupportedStrictJsonSchemaError, "root schema must have type object")
      expect { described_class.make_strict_json_schema("type" => "string") }
        .to raise_error(Fast::Completions::UnsupportedStrictJsonSchemaError, "root schema must have type object")
      expect { described_class.make_strict_json_schema({}) }
        .to raise_error(Fast::Completions::UnsupportedStrictJsonSchemaError, "root schema must have type object")
    end
  end

  describe "schema_allows_null" do
    it "true arms: type null, type array containing null, const nil, enum containing nil, anyOf variant (recursive)" do
      expect(described_class.schema_allows_null({"type" => "null"})).to be(true)
      expect(described_class.schema_allows_null({"type" => ["string", "null"]})).to be(true)
      expect(described_class.schema_allows_null({"const" => nil})).to be(true)
      expect(described_class.schema_allows_null({"enum" => ["a", nil]})).to be(true)
      expect(described_class.schema_allows_null({"anyOf" => [{"type" => "string"}, {"type" => "null"}]})).to be(true)
      expect(described_class.schema_allows_null({"anyOf" => [{"enum" => [nil]}]})).to be(true) # recursion
    end

    it "false arms: an ABSENT const is not null-allowing (JS undefined ≠ null), plain types, non-Hash" do
      expect(described_class.schema_allows_null({"type" => "string"})).to be(false)
      expect(described_class.schema_allows_null({"type" => ["string", "number"]})).to be(false)
      expect(described_class.schema_allows_null({"enum" => ["a"]})).to be(false)
      expect(described_class.schema_allows_null({"anyOf" => [{"type" => "string"}]})).to be(false)
      expect(described_class.schema_allows_null("string")).to be(false)
      expect(described_class.schema_allows_null(nil)).to be(false)
    end
  end

  describe "resolve_json_schema_strict_sampling" do
    it "nil/undeclared/false configs resolve nil; declared + supportable on a strict dialect resolves true" do
      expect(described_class.resolve_json_schema_strict_sampling(sampling_tool(:absent), true)).to be_nil
      expect(described_class.resolve_json_schema_strict_sampling(sampling_tool(false), true)).to be_nil
      expect(described_class.resolve_json_schema_strict_sampling(sampling_tool({"type" => "json_schema", "strict" => "prefer"}), true)).to be(true)
      expect(described_class.resolve_json_schema_strict_sampling(sampling_tool({"type" => "json_schema", "strict" => "require"}), true)).to be(true)
    end

    it "non-json_schema configs resolve nil (pi's grammar-carrying Tool shape; the gem DSL refuses to declare them)" do
      grammar_tool = Struct.new(:name, :parameters, :constrained_sampling)
        .new("read", {"type" => "object", "properties" => {}}, {"type" => "grammar"})
      expect(described_class.resolve_json_schema_strict_sampling(grammar_tool, true)).to be_nil
      expect(described_class.resolve_json_schema_strict_sampling(grammar_tool, false)).to be_nil
    end

    it "prefer falls back silently to nil on an unsupportable schema AND on an unsupported dialect" do
      unsupportable = {"type" => "object", "properties" => {"x" => {"$ref" => "#/$defs/x"}}}
      expect(described_class.resolve_json_schema_strict_sampling(
        sampling_tool({"type" => "json_schema", "strict" => "prefer"}, schema: unsupportable), true
      )).to be_nil
      expect(described_class.resolve_json_schema_strict_sampling(sampling_tool({"type" => "json_schema", "strict" => "prefer"}), false)).to be_nil
    end

    it "require raises BOTH pi templates verbatim" do
      unsupportable = {"type" => "object", "properties" => {"x" => {"allOf" => []}}}
      expect {
        described_class.resolve_json_schema_strict_sampling(
          sampling_tool({"type" => "json_schema", "strict" => "require"}, schema: unsupportable), true
        )
      }.to raise_error(
        Fast::Completions::ConstrainedSamplingError,
        'Tool "read" requires JSON-schema constrained sampling, but allOf schemas are unsupported.'
      )
      expect {
        described_class.resolve_json_schema_strict_sampling(
          sampling_tool({"type" => "json_schema", "strict" => "require"}), false
        )
      }.to raise_error(
        Fast::Completions::ConstrainedSamplingError,
        'Tool "read" requires JSON-schema constrained sampling, but strict tools are unsupported.'
      )
    end

    it "require on an unsupported dialect never even looks at the schema (dialect arm first)" do
      booby_trapped = {"type" => "object", "properties" => {"x" => BOMB}}
      expect {
        described_class.resolve_json_schema_strict_sampling(
          sampling_tool({"type" => "json_schema", "strict" => "require"}, schema: booby_trapped), false
        )
      }.to raise_error(
        Fast::Completions::ConstrainedSamplingError,
        'Tool "read" requires JSON-schema constrained sampling, but strict tools are unsupported.'
      )
    end

    it "catches ONLY the unsupportable-schema class — any other error propagates (pi's rethrow)" do
      booby_trapped = {"type" => "object", "properties" => {"x" => BOMB}}
      expect {
        described_class.resolve_json_schema_strict_sampling(
          sampling_tool({"type" => "json_schema", "strict" => "prefer"}, schema: booby_trapped), true
        )
      }.to raise_error(RuntimeError, /provider keyword hook/)
    end
  end

  describe "the no-mutation property" do
    it "the declared parameters deep-equal their pre-call snapshot AFTER a strict build; the emitted schema is a DIFFERENT object" do
      snapshot = Marshal.load(Marshal.dump(DECLARED))
      emitted = described_class.make_strict_json_schema(DECLARED)
      expect(DECLARED).to eq(snapshot)                     # nothing mutated, nested included
      expect(emitted).not_to equal(DECLARED)               # not the declared object
      expect(emitted["properties"]).not_to equal(DECLARED["properties"])
      expect(emitted["properties"]["offset"]).not_to equal(DECLARED["properties"]["offset"])
      # and the resolver agrees, through the public tool surface
      tool = sampling_tool({"type" => "json_schema", "strict" => "prefer"})
      described_class.resolve_json_schema_strict_sampling(tool, true)
      expect(tool.parameters).to eq(snapshot)
    end
  end
end
