# src/harness/core/session.cr
require "../events"
require "../config_access"

module Harness
  # The append-only `SessionEvent` log. Facts appended here are broadcast
  # through `session/event` (bubbling up the context tree) and optionally
  # persisted as JSONL so they survive a reload.
  class Sessions < Cordis::Service
    @log = [] of SessionEvent
    @file : File?

    def initialize(@ctx : Cordis::Context, persist_path : String? = nil)
      @file = persist_path.try { |path| File.open(path, "a") }
    end

    # Append a fact, persist it, and broadcast it. Returns the event.
    def append(session_id : String, kind : String, data : JSON::Any = JSON::Any.new(nil)) : SessionEvent
      event = SessionEvent.new(session_id, kind, data)
      @log << event
      if file = @file
        file.puts(%({"session_id":#{event.session_id.to_json},"kind":#{event.kind.to_json},"data":#{event.data.to_json},"at":#{event.at.to_rfc3339.to_json}}))
        file.flush
      end
      @ctx.emit(event)
      event
    end

    # The full log, or only the events of one session.
    def log(session_id : String? = nil) : Array(SessionEvent)
      if session_id
        @log.select { |e| e.session_id == session_id }
      else
        @log.dup
      end
    end

    def close : Nil
      @file.try(&.close)
      @file = nil
    end
  end
end

Cordis.register("core/session") do |ctx, config|
  persist  = Harness::Cfg.str(config, "persist")
  sessions = Harness::Sessions.new(ctx, persist)
  ctx.effect { sessions.close }
  ctx["sessions"] = sessions
end
