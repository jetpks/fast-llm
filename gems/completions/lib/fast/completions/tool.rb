# frozen_string_literal: true

module Fast
  module Completions
    # Class-level tool declaration (Specification §11): description,
    # optional tool_name override (default = the class name), parameters
    # schema (emitted VERBATIM on the wire — the consumer's schema is the
    # bytes, §9.2). #execute returns a String, a Hash (JSON-generated for
    # the result text), or {error: "..."} for an error result.
    class Tool
      class << self
        def description(text = nil)
          text ? @description = text : @description
        end

        def tool_name(name = nil)
          name ? @tool_name = name : @tool_name
        end

        def parameters(schema = nil, &block)
          if block
            @parameters = block.call
          elsif schema
            @parameters = schema
          end
          @parameters || {"type" => "object", "properties" => {}}
        end
      end

      # Instance readers forward to the class declaration.
      def description = self.class.description
      def tool_name = self.class.tool_name
      def parameters = self.class.parameters

      # The wire name: the declared tool_name if set, else the class name (§11).
      def name
        self.class.tool_name || self.class.name.to_s.split("::").last
      end

      def description = self.class.description
      def parameters = self.class.parameters

      # Subclasses implement; the Chat calls it with the parsed arguments
      # splashed as keywords.
      def execute(**_arguments)
        raise NotImplementedError, "#{self.class} must implement #execute"
      end
    end
  end
end
