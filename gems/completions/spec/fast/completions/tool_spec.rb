# frozen_string_literal: true

# Tool + Cancellation pins (Specification §11).
require "fast/completions"

RSpec.describe Fast::Completions::Tool do
  it "defaults: no description, empty-object parameters; anonymous classes have no name" do
    tool = Class.new(described_class).new
    expect(tool.description).to be_nil
    expect(tool.name).to be_nil # anonymous DSL classes carry no class name
    expect(tool.parameters).to eq({"type" => "object", "properties" => {}})
  end

  it "declares description, tool_name override, and parameters (§11 shape)" do
    tool = Class.new(described_class) do
      description "Read file contents."
      tool_name "read_file"
      parameters do
        {"type" => "object", "required" => ["path"], "properties" => {"path" => {"type" => "string"}}}
      end

      def execute(path:)
        "contents of #{path}"
      end
    end.new
    expect(tool.description).to eq("Read file contents.")
    expect(tool.name).to eq("read_file") # tool_name wins over the class name
    expect(tool.execute(path: "a.rb")).to eq("contents of a.rb")
  end

  it "uses the class name when no tool_name is declared (§11)" do
    class MyDeclaredTool < described_class
      def execute = "ok"
    end
    expect(MyDeclaredTool.new.name).to eq("MyDeclaredTool")
  end

  it "instances and classes both read the declaration" do
    klass = Class.new(described_class) { description "d" }
    expect(klass.new.description).to eq("d")
    expect(klass.description).to eq("d")
  end

  it "#execute is the subclass's job (base raises NotImplementedError)" do
    expect { described_class.new.execute }.to raise_error(NotImplementedError)
  end

  describe "constrained_sampling declaration (I63 — pi types.ts :736-754)" do
    it "defaults to nil (undeclared — no strict participation), readable from class and instance" do
      klass = Class.new(described_class)
      expect(klass.constrained_sampling).to be_nil
      expect(klass.new.constrained_sampling).to be_nil
    end

    it "accepts false (the explicit opt-out) and the mirrored json_schema shape; readable from class and instance" do
      opt_out = Class.new(described_class) { constrained_sampling false }
      expect(opt_out.constrained_sampling).to be(false)
      expect(opt_out.new.constrained_sampling).to be(false)

      prefer = Class.new(described_class) { constrained_sampling "type" => "json_schema", "strict" => "prefer" }
      expect(prefer.constrained_sampling).to eq("type" => "json_schema", "strict" => "prefer")
      expect(prefer.new.constrained_sampling).to eq("type" => "json_schema", "strict" => "prefer")

      require_shape = {"type" => "json_schema", "strict" => "require"}
      required = Class.new(described_class) { constrained_sampling("type" => "json_schema", "strict" => "require") }
      expect(required.constrained_sampling).to eq(require_shape)
      expect(required.new.constrained_sampling).to eq(require_shape)
    end

    it "raises ArgumentError AT DECLARATION TIME on any other shape" do
      expect { Class.new(described_class) { constrained_sampling "type" => "grammar" } }
        .to raise_error(ArgumentError, /constrained_sampling/) # the named exclusion: nothing half-anticipates grammar
      expect { Class.new(described_class) { constrained_sampling "type" => "json_schema", "strict" => "sometimes" } }
        .to raise_error(ArgumentError, /constrained_sampling/)
      expect { Class.new(described_class) { constrained_sampling "type" => "json_schema" } }
        .to raise_error(ArgumentError, /constrained_sampling/) # missing strict
      expect { Class.new(described_class) { constrained_sampling "strict" => "prefer" } }
        .to raise_error(ArgumentError, /constrained_sampling/) # missing type
      expect { Class.new(described_class) { constrained_sampling "prefer" } }
        .to raise_error(ArgumentError, /constrained_sampling/)
      expect { Class.new(described_class) { constrained_sampling nil } }
        .to raise_error(ArgumentError, /constrained_sampling/)
      expect { Class.new(described_class) { constrained_sampling true } }
        .to raise_error(ArgumentError, /constrained_sampling/)
    end
  end
end
