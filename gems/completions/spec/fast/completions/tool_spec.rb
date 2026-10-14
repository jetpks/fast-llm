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
end
