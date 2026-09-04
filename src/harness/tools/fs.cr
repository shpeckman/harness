# src/harness/tools/fs.cr
require "json"
require "../core/tools"

class Harness::Tools
  # Shared workspace-confinement policy: paths resolve against the
  # workspace root, and anything escaping it is rejected. This is the
  # harness's lightweight sandbox boundary for filesystem access.
  abstract class WorkspaceTool < Harness::Tool
    def initialize(@workspace : String)
    end

    private def resolve(path : String) : String
      root = File.expand_path(@workspace)
      full = File.expand_path(path, root)
      unless full == root || full.starts_with?(root + File::SEPARATOR)
        raise "path #{path.inspect} escapes the workspace"
      end
      full
    end

    private def truncate(text : String, limit : Int32 = 100_000) : String
      text.size > limit ? text[0, limit] + "\n...[truncated]" : text
    end
  end

  class ReadFile < WorkspaceTool
    def name : String
      "read_file"
    end

    def description : String
      "Read a file from the workspace and return its contents."
    end

    def parameters : JSON::Any
      JSON.parse(%({"type":"object","properties":{"path":{"type":"string","description":"Path relative to the workspace root"}},"required":["path"]}))
    end

    def call(args : JSON::Any, agent : Harness::Agent?) : String
      truncate(File.read(resolve(args["path"].as_s)))
    end
  end

  class WriteFile < WorkspaceTool
    def name : String
      "write_file"
    end

    def description : String
      "Write content to a file in the workspace, creating it or overwriting it."
    end

    def parameters : JSON::Any
      JSON.parse(%({"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}))
    end

    def call(args : JSON::Any, agent : Harness::Agent?) : String
      path = resolve(args["path"].as_s)
      Dir.mkdir_p(File.dirname(path))
      File.write(path, args["content"].as_s)
      "wrote #{args["content"].as_s.size} bytes to #{args["path"].as_s}"
    end
  end

  class ListDirectory < WorkspaceTool
    def name : String
      "list_directory"
    end

    def description : String
      "List the entries of a workspace directory."
    end

    def parameters : JSON::Any
      JSON.parse(%({"type":"object","properties":{"path":{"type":"string","description":"Directory relative to the workspace root; defaults to the root itself"}}}))
    end

    def call(args : JSON::Any, agent : Harness::Agent?) : String
      path = resolve(args["path"]?.try(&.as_s?) || ".")
      entries = Dir.children(path).sort!.map do |entry|
        File.directory?(File.join(path, entry)) ? "#{entry}/" : entry
      end
      entries.empty? ? "(empty directory)" : entries.join('\n')
    end
  end
end

Cordis.register("tools/fs") do |ctx, config|
  workspace = Harness::Cfg.str(config, "workspace") || Dir.current
  registry  = ctx.service("tools", Harness::Tools)
  ctx.own(registry.register(Harness::Tools::ReadFile.new(workspace)))
  ctx.own(registry.register(Harness::Tools::WriteFile.new(workspace)))
  ctx.own(registry.register(Harness::Tools::ListDirectory.new(workspace)))
end
