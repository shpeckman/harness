# src/harness/core/agent_loop.cr
require "./agent"
require "./session"
require "./system_prompt"
require "../events"

module Harness
  # The default driver: a straightforward tool-calling loop.
  #
  # Each turn: assemble messages (system prompt + history), run one
  # completion, append the assistant message, and either finish (no tool
  # calls) or execute every requested tool through the guarded pipeline and
  # feed the results back. Emits `agent/start`, `agent/message`,
  # `agent/tool-call` and `agent/finish`; durable facts go to the session log.
  class AgentLoop < AgentDriver
    def initialize(@ctx : Cordis::Context, @max_turns : Int32 = 25)
    end

    def run(agent : Agent, prompt : String) : String
      sessions = @ctx.service?("sessions", Sessions)
      sessions.try(&.append(agent.session_id, "message", JSON.parse({role: "user", content: prompt}.to_json)))
      @ctx.emit(AgentStart.new(agent, prompt))

      agent.messages << Message.user(prompt)
      turns = 0

      loop do
        turns += 1
        if turns > @max_turns
          raise "agent loop exceeded #{@max_turns} turns without finishing"
        end

        response = agent.llm.chat(assemble(agent), tool_schemas(agent))
        agent.messages << response.message
        sessions.try(&.append(agent.session_id, "message", JSON.parse({role: "assistant", content: response.text}.to_json)))
        @ctx.emit(AgentMessage.new(agent, response))

        unless response.tool_call?
          @ctx.emit(AgentFinish.new(agent, response.text))
          return response.text
        end

        response.tool_calls.each do |call|
          @ctx.emit(AgentToolCall.new(agent, call))
          result = agent.tools.execute(call, agent)
          agent.messages << Message.tool(call.id, result)
        end
      end
    end

    private def assemble(agent : Agent) : Array(Message)
      messages = [] of Message
      if prompt = @ctx.service?("systemPrompt", SystemPrompt)
        built = prompt.build
        messages << Message.system(built) unless built.empty?
      end
      messages.concat(agent.messages)
      messages
    end

    private def tool_schemas(agent : Agent) : Array(JSON::Any)?
      schemas = agent.tools.schemas(agent.id)
      schemas.empty? ? nil : schemas
    end
  end
end

Cordis.register("core/agent-loop") do |ctx, config|
  max_turns = Harness::Cfg.int(config, "max_turns") || 25
  ctx["agentLoop"] = Harness::AgentLoop.new(ctx, max_turns)
end
