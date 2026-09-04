# spec/agent_loop_spec.cr
require "./spec_helper"

private class ReverseTool < Harness::Tool
  def name : String
    "reverse"
  end

  def description : String
    "Reverse the given text."
  end

  def parameters : JSON::Any
    JSON.parse(%({"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}))
  end

  def call(args : JSON::Any, agent : Harness::Agent?) : String
    args["text"].as_s.reverse
  end
end

describe "the agent loop" do
  it "runs a tool-calling turn and returns the final answer" do
    app  = boot_mock_app
    mock = app.llm.as(Harness::MockAdapter)
    app.tools.register(ReverseTool.new)

    mock.enqueue_tool_call("call-1", "reverse", %({"text":"harness"}))
    mock.enqueue_text("Reversed, it is: ssenrah.")

    events = [] of String
    app.root.on(Harness::AgentStart) { |_| events << "start" }
    app.root.on(Harness::AgentMessage) { |_| events << "message" }
    app.root.on(Harness::AgentToolCall) { |_| events << "tool-call" }
    app.root.on(Harness::AgentFinish) { |_| events << "finish" }

    agent  = app.agents.create
    answer = agent.run("Reverse the word harness.")

    answer.should eq "Reversed, it is: ssenrah."
    events.should eq ["start", "message", "tool-call", "message", "finish"]

    # The loop fed the tool result back to the model on the second turn.
    second_request = mock.requests[1]
    tool_message   = second_request.find { |m| m.role == "tool" }.not_nil!
    tool_message.tool_call_id.should eq "call-1"
    tool_message.content.should eq "ssenrah"

    # Durable facts landed in the session log.
    kinds = app.sessions.log(agent.session_id).map(&.kind)
    kinds.should eq ["message", "message", "tool-call", "tool-result", "message"]
  end

  it "finishes immediately when the model requests no tool" do
    app  = boot_mock_app
    mock = app.llm.as(Harness::MockAdapter)
    mock.enqueue_text("Just an answer.")

    agent = app.agents.create
    agent.run("Say something.").should eq "Just an answer."
    mock.requests.size.should eq 1
  end

  it "prepends the assembled system prompt" do
    app  = boot_mock_app
    mock = app.llm.as(Harness::MockAdapter)
    mock.enqueue_text("ok")

    agent = app.agents.create
    agent.run("hi")
    first = mock.requests.first.first
    first.role.should eq "system"
    first.content.not_nil!.should contain "Harness agent"
  end

  it "aborts after max_turns" do
    patch = <<-YAML
    rows:
      - id: core/agent-loop
        config:
          max_turns: 2
    YAML
    app  = boot_mock_app([patch])
    mock = app.llm.as(Harness::MockAdapter)
    app.tools.register(ReverseTool.new)
    3.times { |i| mock.enqueue_tool_call("c#{i}", "reverse", %({"text":"x"})) }

    agent = app.agents.create
    expect_raises(Exception, /exceeded 2 turns/) { agent.run("loop forever") }
  end

  it "replaces the driver when the agent-loop row is patched to another plugin" do
    Cordis.register("spec/echo-loop") do |ctx, config|
      ctx["agentLoop"] = SpecEchoDriver.new
    end
    patch = <<-YAML
    rows:
      - id: core/agent-loop
        plugin: spec/echo-loop
        config: {}
    YAML
    app   = boot_mock_app([patch])
    agent = app.agents.create
    agent.run("anything").should eq "echo-driver: anything"
  end
end

private class SpecEchoDriver < Harness::AgentDriver
  def run(agent : Harness::Agent, prompt : String) : String
    "echo-driver: #{prompt}"
  end
end
