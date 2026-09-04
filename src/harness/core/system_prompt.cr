# src/harness/core/system_prompt.cr
require "../config_access"

module Harness
  # Prompt-section assembly. Plugins contribute titled sections; adding a
  # section is an effect, so a plugin's contribution disappears when it
  # unloads. `AgentLoop` prepends `build` to every completion.
  class SystemPrompt < Cordis::Service
    @sections = [] of {String, String}

    def add(title : String, content : String) : Cordis::Disposable
      entry = {title, content}
      @sections << entry
      Cordis::CallbackDisposable.new { @sections.delete(entry); nil }
    end

    def build : String
      @sections.map { |(title, content)| "## #{title}\n\n#{content}" }.join("\n\n")
    end

    def empty? : Bool
      @sections.empty?
    end
  end

  DEFAULT_IDENTITY = <<-TEXT
  You are a Harness agent running inside an everything-is-a-plugin agent
  harness. You can read and edit workspace files, run commands, and maintain
  a plan. Prefer tool calls over prose when acting on the workspace; report
  results truthfully, including failures.
  TEXT
end

Cordis.register("core/system-prompt") do |ctx, config|
  prompt = Harness::SystemPrompt.new
  prompt.add("Identity", Harness::Cfg.str(config, "identity") || Harness::DEFAULT_IDENTITY)
  if extra = Harness::Cfg.arr(config, "instructions")
    extra.each { |line| prompt.add("Instructions", line.as_s) }
  end
  ctx["systemPrompt"] = prompt
end
