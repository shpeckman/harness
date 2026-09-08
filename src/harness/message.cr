# src/harness/message.cr
require "json"

module Harness
  # A tool invocation requested by the model. `arguments` is a raw JSON
  # string, matching the OpenAI/DeepSeek wire format.
  struct ToolCall
    getter id        : String
    getter name      : String
    getter arguments : String

    def initialize(@id : String, @name : String, @arguments : String)
    end

    def parsed_arguments : JSON::Any
      JSON.parse(arguments)
    end
  end

  # The message vocabulary shared by every LLM adapter. Roles follow the
  # OpenAI chat-completions convention: system, user, assistant, tool.
  struct Message
    getter role         : String
    getter content      : String?
    getter tool_calls   : Array(ToolCall)?
    getter tool_call_id : String?
    getter reasoning    : String?

    def initialize(@role : String, @content : String? = nil,
                   @tool_calls   : Array(ToolCall)? = nil,
                   @tool_call_id : String? = nil,
                   @reasoning    : String? = nil)
    end

    def self.system(content : String) : Message
      new("system", content)
    end

    def self.user(content : String) : Message
      new("user", content)
    end

    def self.assistant(content : String? = nil, tool_calls : Array(ToolCall)? = nil, reasoning : String? = nil) : Message
      new("assistant", content, tool_calls, reasoning: reasoning)
    end

    def self.tool(call_id : String, content : String) : Message
      new("tool", content, tool_call_id: call_id)
    end

    def tool_call? : Bool
      if calls = @tool_calls
        !calls.empty?
      else
        false
      end
    end
  end
end
