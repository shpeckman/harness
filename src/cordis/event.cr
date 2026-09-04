# src/cordis/event.cr
module Cordis
  # Base class for typed event payloads. Subclasses define a `NAME` constant
  # (the wire name, e.g. `"session/event"` or `"agent/tool-call"`) and carry
  # typed fields.
  #
  #     class Ping < Cordis::Event
  #       NAME = "app/ping"
  #       getter at : Time
  #
  #       def initialize(@at = Time.utc); end
  #     end
  abstract class Event
    NAME = "event"

    macro inherited
      def name : String
        NAME
      end
    end
  end

  # A per-context listener registry. `Context#emit` delivers here and then
  # bubbles to ancestor contexts.
  class Emitter
    @listeners = {} of String => Array(Event -> Nil)

    # Subscribe to an event name. Returns a disposable that removes the
    # listener — subscriptions are effects.
    def on(name : String, &block : Event -> Nil) : Disposable
      list = (@listeners[name] ||= [] of Event -> Nil)
      list << block
      CallbackDisposable.new { list.delete(block); nil }
    end

    # Subscribe once; the listener removes itself after the first delivery.
    def once(name : String, &block : Event -> Nil) : Disposable
      cell = [] of Disposable
      d = on(name) do |event|
        cell.each(&.dispose)
        block.call(event)
      end
      cell << d
      d
    end

    # Deliver to this emitter's listeners only. Iterates over a copy so
    # listeners may dispose themselves (or others) during delivery.
    def deliver(event : Event) : Nil
      if list = @listeners[event.name]?
        list.dup.each { |handler| handler.call(event) }
      end
    end

    def listener_count(name : String) : Int32
      @listeners[name]?.try(&.size) || 0
    end
  end
end
