# frozen_string_literal: true

module Fast
  module Completions
    # JSON-schema constrained sampling (I63) — the strict rewrite that lets
    # a declared tool ship forced property emission on a strict dialect.
    # Port of pi packages/ai/src/api/constrained-sampling.ts @ f1b2e77f5
    # (the JSON-schema half; the grammar half is deliberately NOT ported —
    # nothing half-anticipates grammar). Message bytes are pi's literals
    # verbatim: they are the parity observable. Check order inside
    # make_json_schema_node_strict is pi's exactly — which message throws
    # first is observable behavior.
    module ConstrainedSampling
      # pi constrained-sampling.ts :17-34 (16 keys — the frozen order IS
      # the first-present-key-wins order). NOTE: the iteration Grounds say
      # "20 keys"; pi's array holds 16 and the Grounds enumerate the same
      # 16 in the same order — the count numeral in the brief is wrong,
      # pi is the oracle.
      UNSUPPORTED_STRICT_SCHEMA_KEYS = [
        "$ref",
        "$defs",
        "definitions",
        "allOf",
        "oneOf",
        "patternProperties",
        "dependentSchemas",
        "dependencies",
        "unevaluatedProperties",
        "propertyNames",
        "contains",
        "prefixItems",
        "not",
        "if",
        "then",
        "else",
      ].freeze

      module_function

      # pi :156-178. `true` (strict) or `nil` (loose). Only
      # UnsupportedStrictJsonSchemaError is caught — any other error
      # propagates (pi's rethrow).
      def resolve_json_schema_strict_sampling(tool, supports_strict_mode)
        config = tool.constrained_sampling
        return nil if config.nil? || config == false || config["type"] != "json_schema"

        if supports_strict_mode
          begin
            make_strict_json_schema(tool.parameters)
            return true
          rescue UnsupportedStrictJsonSchemaError => reason
            return nil if config["strict"] != "require" # silent loose fallback

            raise ConstrainedSamplingError,
              "Tool \"#{tool.name}\" requires JSON-schema constrained sampling, but #{reason.message}."
          end
        end
        if config["strict"] == "require"
          raise ConstrainedSamplingError,
            "Tool \"#{tool.name}\" requires JSON-schema constrained sampling, but strict tools are unsupported."
        end
        nil
      end

      # pi makeStrictJsonSchema :137-151: deep-copy FIRST (the caller's
      # schema — nested included — is never mutated), then the root arms
      # use the root-specific message (differs from the nested
      # "boolean schemas…" arm), then the root type must be "object".
      def make_strict_json_schema(schema)
        cloned = deep_copy(schema)
        raise UnsupportedStrictJsonSchemaError, "root schema must have type object" unless cloned.is_a?(Hash)

        make_json_schema_node_strict(cloned)
        raise UnsupportedStrictJsonSchemaError, "root schema must have type object" unless cloned["type"] == "object"

        cloned
      end

      # pi makeJsonSchemaNodeStrict :64-134, IN PLACE on the (cloned) node.
      def make_json_schema_node_strict(node)
        # JS isJsonSchemaObject: object, not null, not array. Everything
        # else — booleans, null, arrays, scalars — throws here (a nil
        # property value hits this arm: JS undefined equivalence).
        raise UnsupportedStrictJsonSchemaError, "boolean schemas are unsupported" unless node.is_a?(Hash)

        # JS `schema[key] !== undefined`: present-with-any-value (JSON null
        # included) throws; Ruby key? is the exact equivalence.
        UNSUPPORTED_STRICT_SCHEMA_KEYS.each do |key|
          raise UnsupportedStrictJsonSchemaError, "#{key} schemas are unsupported" if node.key?(key)
        end

        # pi's optional isUnsupportedKeyword provider hook is NOT ported:
        # pi's own call sites pass none (Recorded residual R2).

        if node.key?("anyOf") # pi :76-89
          raise UnsupportedStrictJsonSchemaError, "anyOf must contain at least one schema" if
            !node["anyOf"].is_a?(Array) || node["anyOf"].empty?

          node["anyOf"].each do |variant|
            raise UnsupportedStrictJsonSchemaError, "object and array unions are unsupported" if structured_schema?(variant)

            make_json_schema_node_strict(variant)
          end
        end

        if node.key?("items") # pi :91-96
          raise UnsupportedStrictJsonSchemaError, "tuple schemas are unsupported" if node["items"].is_a?(Array)

          make_json_schema_node_strict(node["items"])
        end

        # JS `schema.type === "object"` — the string, strictly.
        object_schema = node["type"] == "object"
        if node.key?("properties") && !object_schema
          raise UnsupportedStrictJsonSchemaError, "properties require type object"
        end
        return unless object_schema # non-object-typed nodes return here

        # JS `!== false`: only exactly boolean false passes.
        if node.key?("additionalProperties") && node["additionalProperties"] != false
          raise UnsupportedStrictJsonSchemaError, "schema-valued or true additionalProperties is unsupported"
        end
        if node.key?("properties") && !node["properties"].is_a?(Hash)
          raise UnsupportedStrictJsonSchemaError, "object properties must be a schema map"
        end
        if node.key?("required") &&
            (!node["required"].is_a?(Array) || node["required"].any? { |key| !key.is_a?(String) })
          raise UnsupportedStrictJsonSchemaError, "object required must be a string array"
        end

        properties = node.key?("properties") ? node["properties"] : {}
        property_names = properties.keys
        required = node.key?("required") ? node["required"] : []
        if required.any? { |key| !property_names.include?(key) }
          raise UnsupportedStrictJsonSchemaError, "required contains an unknown property"
        end

        properties.each do |key, property|
          make_json_schema_node_strict(property)
          if !required.include?(key) && !schema_allows_null(property)
            # Reassignment keeps the key's hash position (JS and Ruby alike).
            properties[key] = {"anyOf" => [property, {"type" => "null"}]}
          end
        end
        node["required"] = property_names          # existing key keeps its position
        node["additionalProperties"] = false       # absent key appends
      end

      # pi schemaAllowsNull :54-60. The const arm needs the key-present
      # check: JS `schema.const === null` is false when the key is absent
      # (undefined ≠ null); Ruby `hash["const"].nil?` alone would read an
      # ABSENT const as null-allowing and skip the wrap.
      def schema_allows_null(schema)
        return false unless schema.is_a?(Hash)

        type = schema["type"]
        return true if type == "null" || (type.is_a?(Array) && type.include?("null"))
        return true if schema.key?("const") && schema["const"].nil?
        return true if schema["enum"].is_a?(Array) && schema["enum"].include?(nil)

        schema["anyOf"].is_a?(Array) && schema["anyOf"].any? { |variant| schema_allows_null(variant) }
      end

      # pi isStructuredSchema :42-51.
      def structured_schema?(schema)
        return false unless schema.is_a?(Hash)

        types =
          if schema["type"].is_a?(String) then [schema["type"]]
          elsif schema["type"].is_a?(Array) then schema["type"]
          else []
          end
        types.include?("object") || types.include?("array") ||
          schema.key?("properties") || schema.key?("items")
      end

      # structuredClone's role: fresh containers all the way down, so the
      # rewrite (property wraps, required/additionalProperties writes)
      # never reaches the declared Hash. Leaves (strings, numbers, booleans,
      # nil) are immutable in Ruby — no copy needed; frozen strings dup
      # clean by simply being carried over.
      def deep_copy(value)
        case value
        when Hash then value.each_with_object({}) { |(key, val), copy| copy[key] = deep_copy(val) }
        when Array then value.map { |val| deep_copy(val) }
        else value
        end
      end
    end
  end
end
