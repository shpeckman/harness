# src/harness/core/agent.cr
require "random/secure"
require "../message"
require "../llm"
require "./tools"

module Harness
  # A live agent: an id, a session, its working message list, and access to
  # the services it runs on. The `Agent` itself is dumb — the *driver*
  # (`agentLoop` service) decides how a prompt becomes turns, so the loop
  # strategy is replaceable like everything else.
  class Agent
    getter id         : String
    getter session_id : String
    getter ctx        : Cordis::Context
    getter messages = [] of Message

    def initialize(@ctx : Cordis::Context, @session_id : String = "default",
                   @id : String = Random::Secure.hex(8))
    end

    def llm : LLM
      ctx.service("llm", LLM)
    end

    def tools : Tools
      ctx.service("tools", Tools)
    end

    def run(prompt : String) : String
      ctx.service("agentLoop", AgentDriver).run(self, prompt)
    end
  end

  # The live agent registry (`agents` service).
  class Agents < Cordis::Service
    @live = {} of String => Agent

    def initialize(@ctx : Cordis::Context)
    end

    def create(session_id : String = "default") : Agent
      agent = Agent.new(@ctx, session_id: session_id)
      @live[agent.id] = agent
      agent
    end

    def []?(id : String) : Agent?
      @live[id]?
    end

    def each(& : Agent ->) : Nil
      @live.each_value { |agent| yield agent }
    end

    def size : Int32
      @live.size
    end
  end

  # The driver interface mounted as `agentLoop`. Swap the `core/agent-loop`
  # row for your own plugin to change how agents reason (plan-act, tree
  # search, multi-agent delegation, ...).
  abstract class AgentDriver < Cordis::Service
    abstract def run(agent : Agent, prompt : String) : String
  end
end

Cordis.register("core/agent") do |ctx, config|
  ctx["agents"] = Harness::Agents.new(ctx)
end
