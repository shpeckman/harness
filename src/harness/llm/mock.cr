# src/harness/llm/mock.cr
require "../llm"
require "../config_access"

module Harness
  # A scripted model adapter. Mount it with `provider: mock` to run the full
  # harness offline, in tests, or as a reference for what "replace the model
  # from configuration" means: the agent loop cannot tell the difference.
  #
  #     mock = Harness::MockAdapter.new
  #     mock.enqueue_tool_call("call-1", "read_file", %({"path":"README.md"}))
  #     mock.enqueue_text("Done.")
  class MockAdapter < LLM
    # Every message list it was asked to complete (dup'd at call time).
    getter requests = [] of Array(Message)

    @queue = [] of LLMResponse

    def initialize
    end

    # Build a scripted adapter from a config row:
    #
    #     provider: mock
    #     responses:
    #       - tool_call: {id: "c1", name: "read_file", arguments: "{\"path\":\"a.txt\"}"}
    #       - text: "Done."
    def self.from_config(config : YAML::Any) : MockAdapter
      adapter = new
      if responses = Cfg.arr(config, "responses")
        responses.each do |entry|
          if text = Cfg.str(entry, "text")
            adapter.enqueue_text(text)
          elsif call = Cfg.get(entry, "tool_call")
            id = Cfg.str(call, "id") || "call-1"
            name = Cfg.str(call, "name") ||
                   raise ArgumentError.new("llm/llm mock response tool_call missing \"name\"")
            arguments = Cfg.str(call, "arguments") || "{}"
            adapter.enqueue_tool_call(id, name, arguments)
          else
            raise ArgumentError.new("llm/llm mock response needs \"text\" or \"tool_call\"")
          end
        end
      end
      adapter
    end

    def enqueue(response : LLMResponse) : self
      @queue << response
      self
    end

    # Script a plain-text completion.
    def enqueue_text(text : String) : self
      enqueue(LLMResponse.new(Message.assistant(content: text)))
    end

    # Script a completion that requests one tool call.
    def enqueue_tool_call(id : String, name : String, arguments : String) : self
      enqueue(LLMResponse.new(
        Message.assistant(tool_calls: [ToolCall.new(id, name, arguments)]),
        finish_reason: "tool_calls"
      ))
    end

    def pending : Int32
      @queue.size
    end

    def chat(messages : Array(Message), tools : Array(JSON::Any)? = nil) : LLMResponse
      @requests << messages.dup
      @queue.shift? ||
        raise "MockAdapter: no scripted response left (enqueue_text / enqueue_tool_call first)"
    end
  end
end
