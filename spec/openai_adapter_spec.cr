# spec/openai_adapter_spec.cr
require "./spec_helper"
require "http/server"

private COMPLETION = %({"id":"c1","object":"chat.completion","created":1,"model":"m","choices":[{"index":0,"message":{"role":"assistant","content":"hello","reasoning_content":"thinking..."},"finish_reason":"stop"}],"usage":{"prompt_tokens":3,"completion_tokens":2}})

private def stub_server(&block : HTTP::Server::Context -> Nil) : {HTTP::Server, Socket::IPAddress}
  server  = HTTP::Server.new { |context| block.call(context) }
  address = server.bind_tcp("127.0.0.1", 0)
  spawn server.listen
  {server, address}
end

describe Harness::OpenAIAdapter do
  it "preserves the base URL path and round-trips reasoning_content" do
    paths  = [] of String
    bodies = [] of String
    http, address = stub_server do |context|
      paths << context.request.path
      bodies << (context.request.body.try(&.gets_to_end) || "")
      context.response.print(COMPLETION)
    end

    adapter = Harness::OpenAIAdapter.new("key", model: "kimi-k3",
      base_url: "http://127.0.0.1:#{address.port}/v1", prompt_cache_key: "sess-1")
    first = adapter.chat([Harness::Message.user("hi")])
    first.text.should eq "hello"
    first.message.reasoning.should eq "thinking..."
    adapter.chat([Harness::Message.user("hi"), first.message, Harness::Message.user("again")])

    paths.should eq ["/v1/chat/completions", "/v1/chat/completions"]
    body = JSON.parse(bodies[0])
    body["prompt_cache_key"].as_s.should eq "sess-1"
    body["messages"][0]["reasoning_content"]?.should be_nil
    JSON.parse(bodies[1])["messages"][1]["reasoning_content"].as_s.should eq "thinking..."
    adapter.total_prompt_tokens.should eq 6
    adapter.total_completion_tokens.should eq 4
    adapter.last_finish_reason.should eq "stop"
  ensure
    http.try(&.close)
  end

  it "sends reasoning_effort, thinking, and user_id when configured" do
    bodies = [] of String
    http, address = stub_server do |context|
      bodies << (context.request.body.try(&.gets_to_end) || "")
      context.response.print(COMPLETION)
    end

    adapter = Harness::OpenAIAdapter.new("key", model: "deepseek-v4-pro",
      base_url: "http://127.0.0.1:#{address.port}",
      reasoning_effort: "low", thinking: true, user_id: "user-1")
    adapter.chat([Harness::Message.user("hi")])
    body = JSON.parse(bodies[0])
    body["reasoning_effort"].as_s.should eq "low"
    body["thinking"]["type"].as_s.should eq "enabled"
    body["user_id"].as_s.should eq "user-1"
  ensure
    http.try(&.close)
  end

  it "retries 429 responses with backoff and then succeeds" do
    requests = 0
    http, address = stub_server do |context|
      requests += 1
      if requests == 1
        context.response.status_code = 429
        context.response.print(%({"error":{"message":"slow down"}}))
      else
        context.response.print(COMPLETION)
      end
    end

    adapter = Harness::OpenAIAdapter.new("key", model: "m",
      base_url: "http://127.0.0.1:#{address.port}", max_retries: 2)
    adapter.chat([Harness::Message.user("hi")]).text.should eq "hello"
    requests.should eq 2
  ensure
    http.try(&.close)
  end

  it "gives up after max_retries on persistent 429" do
    requests = 0
    http, address = stub_server do |context|
      requests += 1
      context.response.status_code = 429
      context.response.print(%({"error":{"message":"slow down"}}))
    end

    adapter = Harness::OpenAIAdapter.new("key", model: "m",
      base_url: "http://127.0.0.1:#{address.port}", max_retries: 1)
    expect_raises(Exception, /HTTP 429/) do
      adapter.chat([Harness::Message.user("hi")])
    end
    requests.should eq 2
  ensure
    http.try(&.close)
  end

  it "does not retry non-retryable statuses" do
    requests = 0
    http, address = stub_server do |context|
      requests += 1
      context.response.status_code = 400
      context.response.print(%({"error":{"message":"bad request"}}))
    end

    adapter = Harness::OpenAIAdapter.new("key", model: "m",
      base_url: "http://127.0.0.1:#{address.port}")
    expect_raises(Exception, /HTTP 400/) do
      adapter.chat([Harness::Message.user("hi")])
    end
    requests.should eq 1
  ensure
    http.try(&.close)
  end

  it "mounts a kimi provider from configuration" do
    ENV["MOONSHOT_API_KEY"] = "test-key"
    patch = %({"rows":[{"id":"llm/llm","config":{"provider":"kimi","prompt_cache_key":"s1"}}]})
    app   = Harness::App.boot("headless", patches: [patch])
    llm   = app.llm.as(Harness::OpenAIAdapter)
    llm.base_url.should eq "https://api.moonshot.ai/v1"
    llm.model.should eq "kimi-k3"
    app.dispose
  ensure
    ENV.delete("MOONSHOT_API_KEY")
  end
end
