# spec/tools_spec.cr
require "./spec_helper"

private class EchoTool < Harness::Tool
  def name : String
    "echo"
  end

  def description : String
    "Echo the given text back."
  end

  def parameters : JSON::Any
    JSON.parse(%({"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}))
  end

  def call(args : JSON::Any, agent : Harness::Agent?) : String
    "echo: #{args["text"].as_s}"
  end
end

# A minimal profile: registry + policy + session log, no model.
TOOLS_PROFILE = <<-YAML
rows:
  - id: core/session
    plugin: core/session
    config: {}
  - id: core/approval
    plugin: core/approval
    config:
      rules:
        - {tool: "danger", decision: "deny"}
        - {tool: "*", decision: "allow"}
  - id: core/tools
    plugin: core/tools
    config: {}
YAML

private def boot_tools_app : Harness::App
  Harness::App.boot(Harness::Composition.compose(TOOLS_PROFILE))
end

describe Harness::Tools do
  it "registers tools and unregisters them when the disposable is disposed" do
    app = boot_tools_app
    d   = app.tools.register(EchoTool.new)
    app.tools.names.should contain "echo"
    d.dispose
    app.tools.names.should_not contain "echo"
  end

  it "rejects duplicate registrations" do
    app = boot_tools_app
    app.tools.register(EchoTool.new)
    expect_raises(ArgumentError, /already registered/) { app.tools.register(EchoTool.new) }
  end

  it "executes a call and records tool-call/tool-result facts" do
    app = boot_tools_app
    app.tools.register(EchoTool.new)
    result = app.tools.execute(Harness::ToolCall.new("c1", "echo", %({"text":"hi"})))
    result.should eq "echo: hi"

    kinds = app.sessions.log("default").map(&.kind)
    kinds.should eq ["tool-call", "tool-result"]
  end

  it "returns an error string for unknown tools instead of raising" do
    app = boot_tools_app
    app.tools.execute(Harness::ToolCall.new("c1", "nope", "{}")).should contain "unknown tool"
  end

  it "denies calls rejected by the approval policy" do
    app = boot_tools_app
    app.tools.register(EchoTool.new, scope: nil)
    app.tools.register(DangerTool.new)
    result = app.tools.execute(Harness::ToolCall.new("c1", "danger", "{}"))
    result.should contain "denied by approval policy"
    app.sessions.log.should be_empty # denied calls record nothing
  end

  it "captures tool exceptions into error strings" do
    app = boot_tools_app
    app.tools.register(BoomTool.new)
    app.tools.execute(Harness::ToolCall.new("c1", "boom", "{}")).should contain "error:"
  end

  it "lets scoped tools shadow global ones for one agent" do
    app = boot_tools_app
    app.tools.register(EchoTool.new)
    app.tools.register(ShoutTool.new, scope: "agent-1")
    app.tools.execute(Harness::ToolCall.new("c1", "echo", %({"text":"hi"}))).should eq "echo: hi"
    scoped = app.tools.[]?("echo", "agent-1").not_nil!
    scoped.call(JSON.parse(%({"text":"hi"})), nil).should eq "ECHO: HI"
  end

  it "produces OpenAI-style schemas" do
    app = boot_tools_app
    app.tools.register(EchoTool.new)
    schema = app.tools.schemas.first
    schema["type"].should eq "function"
    schema["function"]["name"].should eq "echo"
    schema["function"]["parameters"]["required"].should eq %w[text]
  end
end

private class DangerTool < Harness::Tool
  def name : String
    "danger"
  end

  def description : String
    "Denied by policy."
  end

  def parameters : JSON::Any
    JSON.parse(%({"type":"object"}))
  end

  def call(args : JSON::Any, agent : Harness::Agent?) : String
    "should never run"
  end
end

private class BoomTool < Harness::Tool
  def name : String
    "boom"
  end

  def description : String
    "Always raises."
  end

  def parameters : JSON::Any
    JSON.parse(%({"type":"object"}))
  end

  def call(args : JSON::Any, agent : Harness::Agent?) : String
    raise "kaboom"
  end
end

private class ShoutTool < Harness::Tool
  def name : String
    "echo"
  end

  def description : String
    "Scoped echo that shouts."
  end

  def parameters : JSON::Any
    JSON.parse(%({"type":"object","properties":{"text":{"type":"string"}}}))
  end

  def call(args : JSON::Any, agent : Harness::Agent?) : String
    "ECHO: #{args["text"].as_s.upcase}"
  end
end

describe "built-in workspace tools" do
  it "reads, writes and lists inside the workspace" do
    with_temp_workspace do |dir|
      profile = <<-YAML
      rows:
        - id: core/tools
          plugin: core/tools
          config: {}
        - id: tools/fs
          plugin: tools/fs
          config:
            workspace: #{dir}
      YAML
      app   = Harness::App.boot(Harness::Composition.compose(profile))
      tools = app.tools

      tools.execute(Harness::ToolCall.new("1", "write_file", %({"path":"notes/a.txt","content":"hello"}))).should contain "wrote 5 bytes"
      tools.execute(Harness::ToolCall.new("2", "read_file", %({"path":"notes/a.txt"}))).should eq "hello"
      tools.execute(Harness::ToolCall.new("3", "list_directory", %({"path":"notes"}))).should eq "a.txt"
    end
  end

  it "rejects paths escaping the workspace" do
    with_temp_workspace do |dir|
      profile = <<-YAML
      rows:
        - id: core/tools
          plugin: core/tools
          config: {}
        - id: tools/fs
          plugin: tools/fs
          config:
            workspace: #{dir}
      YAML
      app    = Harness::App.boot(Harness::Composition.compose(profile))
      result = app.tools.execute(Harness::ToolCall.new("1", "read_file", %({"path":"../outside.txt"})))
      result.should contain "escapes the workspace"
    end
  end

  it "runs shell commands in the workspace" do
    with_temp_workspace do |dir|
      profile = <<-YAML
      rows:
        - id: core/tools
          plugin: core/tools
          config: {}
        - id: tools/shell
          plugin: tools/shell
          config:
            workspace: #{dir}
      YAML
      app    = Harness::App.boot(Harness::Composition.compose(profile))
      result = app.tools.execute(Harness::ToolCall.new("1", "run_command", %({"command":"pwd && echo hi"})))
      result.should contain "exit 0"
      result.should contain "hi"
    end
  end
end
