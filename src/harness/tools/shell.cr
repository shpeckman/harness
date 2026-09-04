# src/harness/tools/shell.cr
require "json"
require "../core/tools"

class Harness::Tools
  # Run a shell command in the workspace. This is the most powerful — and
  # most dangerous — built-in tool, which is why the shipped base bundle
  # gates it behind the approval policy (`ask` by default).
  class RunCommand < Harness::Tool
    def initialize(@workspace : String, @timeout : Time::Span = 60.seconds)
    end

    def name : String
      "run_command"
    end

    def description : String
      "Run a shell command in the workspace and return its exit code, stdout and stderr."
    end

    def parameters : JSON::Any
      JSON.parse(%({"type":"object","properties":{"command":{"type":"string","description":"The shell command to run"}},"required":["command"]}))
    end

    def call(args : JSON::Any, agent : Harness::Agent?) : String
      command = args["command"].as_s
      stdout  = IO::Memory.new
      stderr  = IO::Memory.new
      status = Process.run("/bin/sh", {"-c", command},
        chdir: @workspace, output: stdout, error: stderr)
      result = String.build do |io|
        io << "exit " << status.exit_code << '\n'
        io << "stdout:\n" << stdout.to_s
        io << "stderr:\n" << stderr.to_s
      end
      result.size > 100_000 ? result[0, 100_000] + "\n...[truncated]" : result
    end
  end
end

Cordis.register("tools/shell") do |ctx, config|
  workspace = Harness::Cfg.str(config, "workspace") || Dir.current
  registry  = ctx.service("tools", Harness::Tools)
  ctx.own(registry.register(Harness::Tools::RunCommand.new(workspace)))
end
