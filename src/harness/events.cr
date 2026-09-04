# src/harness/events.cr
require "../cordis"
require "./message"

module Harness
  # Durable fact appended to the session log and broadcast through
  # `session/event`. Use one when the fact must survive a reload.
  class SessionEvent < Cordis::Event
    NAME = "session/event"

    getter session_id : String
    getter kind       : String
    getter data       : JSON::Any
    getter at         : Time

    def initialize(@session_id : String, @kind : String,
                   @data : JSON::Any = JSON::Any.new(nil), @at : Time = Time.utc)
    end
  end

  # Base for the live-agent events (`agent/*`). These carry a live `Agent`
  # and are *not* persisted — use session events for facts that must endure.
  abstract class AgentEvent < Cordis::Event
    getter agent : Agent

    def initialize(@agent : Agent)
    end
  end

  class AgentStart < AgentEvent
    NAME = "agent/start"
    getter prompt : String

    def initialize(agent : Agent, @prompt : String)
      super(agent)
    end
  end

  class AgentMessage < AgentEvent
    NAME = "agent/message"
    getter response : LLMResponse

    def initialize(agent : Agent, @response : LLMResponse)
      super(agent)
    end
  end

  class AgentToolCall < AgentEvent
    NAME = "agent/tool-call"
    getter call : ToolCall

    def initialize(agent : Agent, @call : ToolCall)
      super(agent)
    end
  end

  class AgentFinish < AgentEvent
    NAME = "agent/finish"
    getter text : String

    def initialize(agent : Agent, @text : String)
      super(agent)
    end
  end
end
