# spec/sessions_spec.cr
require "./spec_helper"

describe Harness::Sessions do
  it "appends facts and filters the log by session" do
    root = Cordis::Context.new
    root.mount("core/session")
    sessions = root.service("sessions", Harness::Sessions)

    sessions.append("a", "message", JSON.parse(%({"content":"hi"})))
    sessions.append("b", "message")
    sessions.append("a", "tool-call")

    sessions.log.size.should eq 3
    sessions.log("a").map(&.kind).should eq ["message", "tool-call"]
  end

  it "broadcasts session/event up the context tree" do
    root = Cordis::Context.new
    root.mount("core/session")
    seen = [] of Harness::SessionEvent
    root.on(Harness::SessionEvent) { |e| seen << e }

    root.service("sessions", Harness::Sessions).append("s", "message")
    seen.size.should eq 1
    seen.first.session_id.should eq "s"
    seen.first.kind.should eq "message"
  end

  it "persists facts as JSONL and closes on unload" do
    path = File.join(Dir.tempdir, "harness-sessions-#{Random::Secure.hex(6)}.jsonl")
    begin
      root = Cordis::Context.new
      root.mount("core/session", YAML.parse(%({"persist": "#{path}"})))
      sessions = root.service("sessions", Harness::Sessions)
      sessions.append("s", "message", JSON.parse(%({"n":1})))
      root.dispose

      lines = File.read_lines(path).reject(&.empty?)
      lines.size.should eq 1
      parsed = JSON.parse(lines.first)
      parsed["session_id"].should eq "s"
      parsed["kind"].should eq "message"
      parsed["data"]["n"].should eq 1
    ensure
      File.delete(path) if File.exists?(path)
    end
  end
end
