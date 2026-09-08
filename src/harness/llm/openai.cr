# src/harness/llm/openai.cr
require "http/client"
require "json"
require "uri"
require "random"
require "../llm"
require "../config_access"

module Harness
  # An OpenAI-compatible chat-completions adapter. Works against DeepSeek
  # (`https://api.deepseek.com`, the default), Kimi
  # (`https://api.moonshot.ai/v1`), OpenAI, or any endpoint speaking the same
  # protocol. Implements both one-shot `chat` and SSE `stream`.
  #
  # `reasoning_content` is parsed into `Message#reasoning` and re-encoded on
  # later turns: DeepSeek rejects tool-calling history that drops it, and
  # Kimi's preserved-thinking models expect it verbatim.
  #
  # Requests retry with exponential backoff on 429/5xx responses, network
  # errors, and `insufficient_system_resource` finishes (up to
  # `max_retries`).
  class OpenAIAdapter < LLM
    getter model    : String
    getter base_url : String
    getter total_prompt_tokens     = 0
    getter total_completion_tokens = 0
    getter last_finish_reason      : String? = nil

    RETRYABLE_STATUS = [429, 500, 502, 503, 504]

    def initialize(@api_key : String, @model : String,
                   @base_url         : String   = "https://api.deepseek.com",
                   @temperature      : Float64? = nil,
                   @reasoning_effort : String?  = nil,
                   @thinking         : Bool?    = nil,
                   @prompt_cache_key : String?  = nil,
                   @user_id          : String?  = nil,
                   @max_retries      : Int32    = 3)
    end

    def chat(messages : Array(Message), tools : Array(JSON::Any)? = nil) : LLMResponse
      body = build_body(messages, tools, stream: false)
      attempts = 0
      loop do
        response = parse_completion(JSON.parse(post(body)))
        if response.finish_reason == "insufficient_system_resource" && attempts < @max_retries
          sleep backoff(attempts)
          attempts += 1
        else
          return response
        end
      end
    end

    def stream(messages : Array(Message), tools : Array(JSON::Any)? = nil, & : String -> Nil) : LLMResponse
      body       = build_body(messages, tools, stream: true)
      content    = String::Builder.new
      reasoning  = String::Builder.new
      tool_calls = [] of ToolCall
      finish     = "stop"

      post_stream(body) do |event|
        choice = event["choices"]?.try(&.[0]?)
        next unless choice
        if reason = choice["finish_reason"]?.try(&.as_s?)
          finish = reason
        end
        if delta = choice["delta"]?
          if piece = delta["reasoning_content"]?.try(&.as_s?)
            reasoning << piece
          end
          if piece = delta["content"]?.try(&.as_s?)
            content << piece
            yield piece
          end
          accumulate_tool_calls(tool_calls, delta["tool_calls"]?)
        end
      end

      message = Message.assistant(
        content: content.empty? ? nil : content.to_s,
        tool_calls: tool_calls.empty? ? nil : tool_calls,
        reasoning: reasoning.empty? ? nil : reasoning.to_s
      )
      @last_finish_reason = finish
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
          if effort = @reasoning_effort
            json.field "reasoning_effort", effort
          end
          if thinking = @thinking
            json.field "thinking" do
              json.object do
                json.field "type", thinking ? "enabled" : "disabled"
              end
            end
          end
          if cache_key = @prompt_cache_key
            json.field "prompt_cache_key", cache_key
          end
          if user_id = @user_id
            json.field "user_id", user_id
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
        if reasoning = message.reasoning
          json.field "reasoning_content", reasoning
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
      prompt_tokens = usage.try(&.["prompt_tokens"]?.try(&.as_i?))
      completion_tokens = usage.try(&.["completion_tokens"]?.try(&.as_i?))
      @total_prompt_tokens += prompt_tokens || 0
      @total_completion_tokens += completion_tokens || 0
      finish = choice["finish_reason"]?.try(&.as_s?) || "stop"
      @last_finish_reason = finish
      LLMResponse.new(
        Message.assistant(
          content: message["content"]?.try(&.as_s?),
          tool_calls: calls,
          reasoning: message["reasoning_content"]?.try(&.as_s?)),
        finish_reason: finish,
        prompt_tokens: prompt_tokens,
        completion_tokens: completion_tokens
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

    private def endpoint : URI
      URI.parse(@base_url.rstrip('/') + "/chat/completions")
    end

    private def backoff(attempt : Int32) : Time::Span
      (Math.min(2.0 ** attempt, 30.0) * (0.5 + Random.rand)).seconds
    end

    private def headers : HTTP::Headers
      HTTP::Headers{
        "Authorization" => "Bearer #{@api_key}",
        "Content-Type"  => "application/json",
        "Accept"        => "application/json",
      }
    end

    private def new_client(uri : URI) : HTTP::Client
      client = HTTP::Client.new(uri)
      client.connect_timeout = 15.seconds
      client.read_timeout = 5.minutes
      client
    end

    private def post(body : String) : String
      attempts = 0
      loop do
        begin
          uri = endpoint
          client = new_client(uri)
          begin
            response = client.post(uri.request_target, headers: headers, body: body)
            return response.body if response.success?
            unless RETRYABLE_STATUS.includes?(response.status_code) && attempts < @max_retries
              raise "LLM request failed: HTTP #{response.status_code}: #{response.body[0, 500]}"
            end
          ensure
            client.close
          end
        rescue ex : IO::Error | Socket::Error
          raise ex if attempts >= @max_retries
        end
        sleep backoff(attempts)
        attempts += 1
      end
    end

    private class RetryableStreamError < Exception
    end

    private def post_stream(body : String, & : JSON::Any ->) : Nil
      attempts = 0
      loop do
        yielded = false
        begin
          uri = endpoint
          client = new_client(uri)
          stream_headers = headers
          stream_headers["Accept"] = "text/event-stream"
          begin
            client.post(uri.request_target, headers: stream_headers, body: body) do |response|
              unless response.success?
                if RETRYABLE_STATUS.includes?(response.status_code) && attempts < @max_retries
                  raise RetryableStreamError.new("HTTP #{response.status_code}")
                end
                raise "LLM stream failed: HTTP #{response.status_code}: #{response.body_io.gets_to_end[0, 500]}"
              end
              response.body_io.each_line do |line|
                line = line.strip
                next unless line.starts_with?("data:")
                data = line[5..].strip
                break if data == "[DONE]"
                next if data.empty?
                yielded = true
                yield JSON.parse(data)
              end
            end
          ensure
            client.close
          end
          return
        rescue ex : RetryableStreamError
          sleep backoff(attempts)
          attempts += 1
        rescue ex : IO::Error | Socket::Error
          raise ex if yielded || attempts >= @max_retries
          sleep backoff(attempts)
          attempts += 1
        end
      end
    end
  end
end

# The model-adapter seam, mounted as the `llm` service. The provider is
# chosen by configuration; everything above it (agent loop, tools, UI) is
# provider-agnostic.
Cordis.register("llm/llm") do |ctx, config|
  provider = Harness::Cfg.str(config, "provider") || "deepseek"

  key : String? = nil
  model : String? = nil
  base_url : String? = nil

  case provider
  when "deepseek"
    key = Harness::Cfg.str(config, "api_key") || ENV["DEEPSEEK_API_KEY"]? ||
          raise "llm/llm: set config.api_key or the DEEPSEEK_API_KEY environment variable"
    model = Harness::Cfg.str(config, "model") || "deepseek-chat"
    base_url = Harness::Cfg.str(config, "base_url") || "https://api.deepseek.com"
  when "kimi"
    key = Harness::Cfg.str(config, "api_key") || ENV["MOONSHOT_API_KEY"]? || ENV["KIMI_API_KEY"]? ||
          raise "llm/llm: set config.api_key or the MOONSHOT_API_KEY/KIMI_API_KEY environment variable"
    model = Harness::Cfg.str(config, "model") || "kimi-k3"
    base_url = Harness::Cfg.str(config, "base_url") || "https://api.moonshot.ai/v1"
  when "openai-compatible"
    key = Harness::Cfg.str(config, "api_key") || ENV["OPENAI_API_KEY"]? ||
          raise "llm/llm: set config.api_key or the OPENAI_API_KEY environment variable"
    base_url = Harness::Cfg.str(config, "base_url") ||
               raise "llm/llm: config.base_url is required for provider \"openai-compatible\""
    model = Harness::Cfg.str(config, "model") ||
            raise "llm/llm: config.model is required for provider \"openai-compatible\""
  end

  llm : Harness::LLM =
    if provider == "mock"
      Harness::MockAdapter.from_config(config)
    elsif key && model && base_url
      Harness::OpenAIAdapter.new(key, model: model, base_url: base_url,
        temperature: Harness::Cfg.get(config, "temperature").try(&.as_f?),
        reasoning_effort: Harness::Cfg.str(config, "reasoning_effort"),
        thinking: Harness::Cfg.get(config, "thinking").try(&.as_bool?),
        prompt_cache_key: Harness::Cfg.str(config, "prompt_cache_key"),
        user_id: Harness::Cfg.str(config, "user_id"),
        max_retries: Harness::Cfg.int(config, "max_retries") || 3)
    else
      raise "llm/llm: unknown provider #{provider.inspect} (expected deepseek, kimi, openai-compatible, or mock)"
    end
  ctx["llm"] = llm
end
