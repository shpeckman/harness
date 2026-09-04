# src/harness/llm.cr
require "./message"

module Harness
  # One completion step's result.
  class LLMResponse
    getter message           : Message
    getter finish_reason     : String
    getter prompt_tokens     : Int32?
    getter completion_tokens : Int32?

    def initialize(@message : Message, @finish_reason : String = "stop",
                   @prompt_tokens : Int32? = nil, @completion_tokens : Int32? = nil)
    end

    def tool_calls : Array(ToolCall)
      @message.tool_calls || [] of ToolCall
    end

    def tool_call? : Bool
      !tool_calls.empty?
    end

    def text : String
      @message.content || ""
    end
  end

  # The model-adapter seam. Any LLM provider is a plugin that mounts an
  # `LLM` subclass as the `llm` service. Adapters must implement `chat`;
  # `stream` has a non-streaming fallback so simple adapters get it free.
  abstract class LLM < Cordis::Service
    # Run one completion. `tools` is the OpenAI-style function-schema array
    # produced by `Tools#schemas`; nil means "no tools available".
    abstract def chat(messages : Array(Message), tools : Array(JSON::Any)? = nil) : LLMResponse

    # Streaming variant: yields text deltas as they arrive and still returns
    # the assembled response (including any tool calls).
    def stream(messages : Array(Message), tools : Array(JSON::Any)? = nil, & : String -> Nil) : LLMResponse
      response = chat(messages, tools)
      if content = response.message.content
        yield content unless content.empty?
      end
      response
    end
  end
end
