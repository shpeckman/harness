# spec/cordis_spec.cr
require "./spec_helper"

private class Ping < Cordis::Event
  NAME = "spec/ping"
  getter value : Int32

  def initialize(@value : Int32)
  end
end

private class Greeter < Cordis::Service
  def greet : String
    "hello"
  end
end

describe Cordis do
  describe "services" do
    it "registers and resolves from children" do
      root = Cordis::Context.new
      root["greeter"] = Greeter.new
      child = root.mount("spec/noop")
      child.service("greeter", Greeter).greet.should eq "hello"
    end

    it "unwinds a registration when its context disposes" do
      root  = Cordis::Context.new
      child = root.mount("spec/provider")
      child.service("greeter", Greeter).should_not be_nil
      child.dispose
      root.service?("greeter", Greeter).should be_nil
    end

    it "restores the previous service when an inner registration unwinds" do
      root  = Cordis::Context.new
      first = Greeter.new
      root["greeter"] = first
      d = root["greeter"] = Greeter.new
      root["greeter"].should_not eq first
      d.dispose
      root["greeter"].should eq first
    end

    it "raises a KeyError for a missing service" do
      root = Cordis::Context.new
      expect_raises(KeyError, /no Cordis service/) { root["nope"] }
    end
  end

  describe "events" do
    it "delivers to subscribers and bubbles up the tree" do
      root  = Cordis::Context.new
      child = root.mount("spec/noop")
      seen  = [] of Int32
      root.on(Ping) { |e| seen << e.value }
      child.emit(Ping.new(42))
      seen.should eq [42]
    end

    it "does not deliver downward" do
      root  = Cordis::Context.new
      child = root.mount("spec/noop")
      seen  = 0
      child.on(Ping) { |_| seen += 1 }
      root.emit(Ping.new(1))
      seen.should eq 0
    end

    it "removes listeners when their context unloads" do
      root  = Cordis::Context.new
      child = root.mount("spec/noop")
      seen  = 0
      child.on(Ping) { |_| seen += 1 }
      child.dispose
      root.emit(Ping.new(1))
      seen.should eq 0
    end

    it "supports once listeners disposing mid-delivery" do
      root = Cordis::Context.new
      seen = 0
      root.once("spec/ping") { |_| seen += 1 }
      root.emit(Ping.new(1))
      root.emit(Ping.new(2))
      seen.should eq 1
    end
  end

  describe "effects and the plugin tree" do
    it "unwinds effects in reverse order" do
      root  = Cordis::Context.new
      order = [] of Int32
      root.effect { order << 1 }
      root.effect { order << 2 }
      root.effect { order << 3 }
      root.dispose
      order.should eq [3, 2, 1]
    end

    it "disposes children newest-first and is idempotent" do
      root  = Cordis::Context.new
      order = [] of String
      a     = root.mount("spec/noop")
      b     = root.mount("spec/noop")
      a.effect { order << "a" }
      b.effect { order << "b" }
      root.dispose
      root.dispose
      order.should eq ["b", "a"]
    end

    it "raises for unknown plugins, listing what is registered" do
      root  = Cordis::Context.new
      error = expect_raises(ArgumentError, /unknown plugin/) { root.mount("nope/nope") }
      error.message.not_nil!.should contain "core/tools"
    end

    it "unwinds a half-mounted plugin when its factory raises" do
      cleaned = false
      Cordis.register("spec/raises") do |ctx, _|
        ctx.effect { cleaned = true }
        raise "boom"
      end
      root = Cordis::Context.new
      expect_raises(Exception, "boom") { root.mount("spec/raises") }
      cleaned.should be_true
    end

    it "ties foreign disposables to the context with own" do
      root     = Cordis::Context.new
      disposed = false
      root.own(Cordis::CallbackDisposable.new { disposed = true })
      root.dispose
      disposed.should be_true
    end
  end
end

Cordis.register("spec/noop") do |ctx, config|
end

Cordis.register("spec/provider") do |ctx, config|
  ctx["greeter"] = Greeter.new
end
