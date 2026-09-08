# src/harness/llm/openai.cr
require "http/client"
require "json"
require "uri"
require "../llm"
require "../config_access"

module Harness
  # An OpenAI-compatible chat-completions adapter. Works against DeepSeek
  # (`https://api.deepseek.com`, the default), OpenAI, or any endpoint
  # speaking the same protocol. Implements both one-shot `chat` and SSE
  # `stream`.
  class OpenAIAdapter < LLM
    getter model    : String
    getter base_url : String

    def initialize(@api_key : String, @model : String,
                   @base_url    : String   = "https://api.deepseek.com",
                   @temperature : Float64? = nil)
    end

    def chat(messages : Array(Message), tools : Array(JSON::Any)? = nil) : LLMResponse
      body = build_body(messages, tools, stream: false)
      json = JSON.parse(post(body))
      parse_completion(json)
    end

    def stream(messages : Array(Message), tools : Array(JSON::Any)? = nil, & : String -> Nil) : LLMResponse
      body       = build_body(messages, tools, stream: true)
      content    = String::Builder.new
      tool_calls = [] of ToolCall
      finish     = "stop"

      post_stream(body) do |event|
        choice = event["choices"]?.try(&.[0]?)
        next unless choice
        if reason = choice["finish_reason"]?.try(&.as_s?)
          finish = reason
        end
        if delta = choice["delta"]?
          if piece = delta["content"]?.try(&.as_s?)
            content << piece
            yield piece
          end
          accumulate_tool_calls(tool_calls, delta["tool_calls"]?)
        end
      end

      message = Message.assistant(
        content: content.empty? ? nil : content.to_s,
        tool_calls: tool_calls.empty? ? nil : tool_calls
      )
      LLMResponse.new(message, finish_reason: finish)
    end

    # --- wire encoding ----------------------------------------------------

    private def build_body(messages : Array(Message), tools : Array(JSON::Any)?, stream : Bool) : String
      JSON.build do |json|
        json.object do
          json.field "model", @model
          json.field "stream", stream
          if temperature = @temperature
            json.field "temperature", temperature
          end
          json.field "messages" do
            json.array do
              messages.each { |message| encode_message(json, message) }
            end
          end
          if tools
            json.field "tools" do
              json.array do
                tools.each { |tool| tool.to_json(json) }
              end
            end
          end
        end
      end
    end

    private def encode_message(json : JSON::Builder, message : Message) : Nil
      json.object do
        json.field "role", message.role
        if content = message.content
          json.field "content", content
        elsif message.role == "assistant"
          json.field "content", ""
        end
        if calls = message.tool_calls
          json.field "tool_calls" do
            json.array do
              calls.each do |call|
                json.object do
                  json.field "id", call.id
                  json.field "type", "function"
                  json.field "function" do
                    json.object do
                      json.field "name", call.name
                      json.field "arguments", call.arguments
                    end
                  end
                end
              end
            end
          end
        end
        if tool_call_id = message.tool_call_id
          json.field "tool_call_id", tool_call_id
        end
      end
    end

    private def parse_completion(json : JSON::Any) : LLMResponse
      choice  = json["choices"][0]
      message = choice["message"]
      calls = message["tool_calls"]?.try(&.as_a.map do |call|
        function = call["function"]
        ToolCall.new(call["id"].as_s, function["name"].as_s, function["arguments"].as_s)
      end)
      usage = json["usage"]?
      LLMResponse.new(
        Message.assistant(content: message["content"]?.try(&.as_s?), tool_calls: calls),
        finish_reason: choice["finish_reason"]?.try(&.as_s?) || "stop",
        prompt_tokens: usage.try(&.["prompt_tokens"]?.try(&.as_i?)),
        completion_tokens: usage.try(&.["completion_tokens"]?.try(&.as_i?))
      )
    end

    # Streaming tool-call deltas arrive indexed and fragmented; reassemble.
    private def accumulate_tool_calls(into : Array(ToolCall), deltas : JSON::Any?) : Nil
      return unless deltas
      deltas.as_a.each do |delta|
        index = delta["index"].as_i
        while into.size <= index
          into << ToolCall.new("", "", "")
        end
        current   = into[index]
        id        = delta["id"]?.try(&.as_s?) || current.id
        name      = current.name
        arguments = current.arguments
        if function = delta["function"]?
          name = function["name"]?.try(&.as_s?) || name
          if fragment = function["arguments"]?.try(&.as_s?)
            arguments += fragment
          end
        end
        into[index] = ToolCall.new(id, name, arguments)
      end
    end

    # --- transport ----------------------------------------------------------

    private def client : HTTP::Client
      uri    = URI.parse(@base_url)
      client = HTTP::Client.new(uri)
      client.connect_timeout = 15.seconds
      client.read_timeout = 5.minutes
      client
    end

    private def headers : HTTP::Headers
      HTTP::Headers{
        "Authorization" => "Bearer #{@api_key}",
        "Content-Type"  => "application/json",
        "Accept"        => "application/json",
      }
    end

    private def post(body : String) : String
      client = self.client
      begin
        response = client.post("/chat/completions", headers: headers, body: body)
        unless response.success?
          raise "LLM request failed: HTTP #{response.status_code}: #{response.body[0, 500]}"
        end
        response.body
      ensure
        client.close
      end
    end

    private def post_stream(body : String, & : JSON::Any ->) : Nil
      client         = self.client
      stream_headers = headers
      stream_headers["Accept"] = "text/event-stream"
      begin
        client.post("/chat/completions", headers: stream_headers, body: body) do |response|
          unless response.success?
            raise "LLM stream failed: HTTP #{response.status_code}: #{response.body_io.gets_to_end[0, 500]}"
          end
          response.body_io.each_line do |line|
            line = line.strip
            next unless line.starts_with?("data:")
            data = line[5..].strip
            break if data == "[DONE]"
            next if data.empty?
            yield JSON.parse(data)
          end
        end
      ensure
        client.close
      end
    end
  end
end

# The model-adapter seam, mounted as the `llm` service. The provider is
# chosen by configuration; everything above it (agent loop, tools, UI) is
# provider-agnostic.
Cordis.register("llm/llm") do |ctx, config|
  provider = Harness::Cfg.str(config, "provider") || "deepseek"
  llm : Harness::LLM = case provider
  when "mock"
    Harness::MockAdapter.from_config(config)
  when "deepseek"
    key = Harness::Cfg.str(config, "api_key") || ENV["DEEPSEEK_API_KEY"]? ||
          raise "llm/llm: set config.api_key or the DEEPSEEK_API_KEY environment variable"
    Harness::OpenAIAdapter.new(key,
      model: Harness::Cfg.str(config, "model") || "deepseek-chat",
      base_url: Harness::Cfg.str(config, "base_url") || "https://api.deepseek.com",
      temperature: Harness::Cfg.get(config, "temperature").try(&.as_f?))
  when "openai-compatible"
    key = Harness::Cfg.str(config, "api_key") || ENV["OPENAI_API_KEY"]? ||
          raise "llm/llm: set config.api_key or the OPENAI_API_KEY environment variable"
    base_url = Harness::Cfg.str(config, "base_url") ||
               raise "llm/llm: config.base_url is required for provider \"openai-compatible\""
    model = Harness::Cfg.str(config, "model") ||
            raise "llm/llm: config.model is required for provider \"openai-compatible\""
    Harness::OpenAIAdapter.new(key, model: model, base_url: base_url,
      temperature: Harness::Cfg.get(config, "temperature").try(&.as_f?))
  else
    raise "llm/llm: unknown provider #{provider.inspect} (expected deepseek, openai-compatible, or mock)"
  end
  ctx["llm"] = llm
end
