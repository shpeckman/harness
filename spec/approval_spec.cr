# spec/approval_spec.cr
require "./spec_helper"

describe Harness::Approval do
  it "allows by default when no rule matches" do
    Harness::Approval.new.authorize("anything").should be_true
  end

  it "applies the first matching rule" do
    approval = Harness::Approval.new([
      {"run_command", Harness::Decision::Deny},
      {"*",           Harness::Decision::Allow},
    ])
    approval.authorize("run_command").should be_false
    approval.authorize("read_file").should be_true
  end

  it "matches glob patterns" do
    approval = Harness::Approval.new([{"fs/*", Harness::Decision::Deny}])
    approval.authorize("fs/read").should be_false
    approval.authorize("shell").should be_true
  end

  it "resolves ask through the handler, denying when none is installed" do
    approval = Harness::Approval.new([{"*", Harness::Decision::Ask}])
    approval.authorize("x").should be_false
    approval.ask_handler = ->(tool : String, detail : String) { tool == "ok_tool" }
    approval.authorize("ok_tool").should be_true
    approval.authorize("bad_tool").should be_false
  end

  it "parses rules from config" do
    config   = YAML.parse(%(rules:\n  - {tool: "run_command", decision: "ask"}\n  - {tool: "*", decision: "allow"}))
    approval = Harness::Approval.from_config(config)
    approval.decide("run_command").should eq Harness::Decision::Ask
    approval.decide("read_file").should eq Harness::Decision::Allow
  end

  it "rejects unknown decisions" do
    expect_raises(ArgumentError, /unknown approval decision/) do
      Harness::Decision.parse("maybe")
    end
  end
end
