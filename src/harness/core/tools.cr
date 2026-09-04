# src/harness/core/tools.cr
require "json"
require "../message"
require "../events"
require "./session"
require "./approval"

module Harness
  # A callable capability. `parameters` is a JSON Schema object describing
  # the arguments; `call` receives them parsed.
  abstract class Tool
    abstract def name : String
    abstract def description : String
    abstract def parameters : JSON::Any
    abstract def call(args : JSON::Any, agent : Agent?) : String

    # The OpenAI/DeepSeek wire schema for this tool.
    def schema : JSON::Any
      JSON.parse({type: "function", function: {name: name, description: description, parameters: parameters}}.to_json)
    end
  end

  # The scoped tool registry and guarded execution pipeline.
  #
  # Tools register globally or scoped to one agent id; scoped registrations
  # shadow global ones for that agent. Registration returns a disposable —
  # plugin authors tie it to their context with `ctx.own`.
  #
  # `execute` is the guard point every model-requested call passes through:
  # lookup -> approval policy -> run -> record to the session log.
  class Tools < Cordis::Service
    @global = {} of String => Tool
    @scoped = {} of String => Hash(String, Tool)

    def initialize(@ctx : Cordis::Context)
    end

    def register(tool : Tool, scope : String? = nil) : Cordis::Disposable
      map = scope ? (@scoped[scope] ||= {} of String => Tool) : @global
      if map.has_key?(tool.name)
        raise ArgumentError.new("tool #{tool.name.inspect} is already registered")
      end
      map[tool.name] = tool
      Cordis::CallbackDisposable.new { map.delete(tool.name); nil }
    end

    def []?(name : String, scope : String? = nil) : Tool?
      if scope
        if specific = @scoped[scope]?
          return specific[name]? if specific.has_key?(name)
        end
      end
      @global[name]?
    end

    def names(scope : String? = nil) : Array(String)
      result = @global.keys
      if scope
        if specific = @scoped[scope]?
          result = (result + specific.keys).uniq
        end
      end
      result.sort!
    end

    # OpenAI-style schemas for everything visible from `scope`.
    def schemas(scope : String? = nil) : Array(JSON::Any)
      tools = @global.values
      if scope
        if specific = @scoped[scope]?
          tools = tools + specific.values
        end
      end
      tools.map(&.schema)
    end

    # Run one model-requested call through the guard pipeline. Never raises
    # for tool-side failures — errors come back as strings so the model can
    # see and recover from them.
    def execute(call : ToolCall, agent : Agent? = nil, session_id : String? = nil) : String
      tool = self.[]?(call.name, agent.try(&.id))
      return "error: unknown tool #{call.name.inspect}" unless tool

      if approval = @ctx.service?("approval", Approval)
        unless approval.authorize(tool.name, call.arguments)
          return "error: tool #{tool.name.inspect} denied by approval policy"
        end
      end

      result = begin
        tool.call(call.parsed_arguments, agent)
      rescue ex
        "error: #{ex.class.name}: #{ex.message}"
      end

      if sessions = @ctx.service?("sessions", Sessions)
        sid = session_id || agent.try(&.session_id) || "default"
        sessions.append(sid, "tool-call", JSON.parse({name: call.name, arguments: call.parsed_arguments}.to_json))
        sessions.append(sid, "tool-result", JSON.parse({name: call.name, result: result}.to_json))
      end

      result
    end
  end
end

Cordis.register("core/tools") do |ctx, config|
  ctx["tools"] = Harness::Tools.new(ctx)
end
