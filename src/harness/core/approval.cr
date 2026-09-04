# src/harness/core/approval.cr
require "../config_access"

module Harness
  enum Decision
    Allow
    Ask
    Deny

    def self.parse(value : String) : Decision
      case value.downcase
      when "allow" then Allow
      when "ask"   then Ask
      when "deny"  then Deny
      else              raise ArgumentError.new("unknown approval decision #{value.inspect}")
      end
    end
  end

  # The permission policy. Ordered rules map tool-name patterns (`*` glob)
  # to a decision; the first match wins and the default is allow. `ask`
  # resolves through a configurable handler — a UI prompt, a callback, or,
  # when no handler is installed, a safe deny.
  class Approval < Cordis::Service
    # (tool name, human-readable detail) -> allowed?
    alias AskHandler = Proc(String, String, Bool)

    property ask_handler : AskHandler?

    getter rules = [] of {String, Decision}

    def initialize(rules : Array({String, Decision}) = [] of {String, Decision})
      @rules = rules
    end

    def self.from_config(config : YAML::Any) : Approval
      parsed = [] of {String, Decision}
      if list = Cfg.arr(config, "rules")
        list.each do |rule|
          tool     = Cfg.str(rule, "tool") || raise ArgumentError.new("approval rule missing \"tool\"")
          decision = Cfg.str(rule, "decision") || raise ArgumentError.new("approval rule missing \"decision\"")
          parsed << {tool, Decision.parse(decision)}
        end
      end
      new(parsed)
    end

    def decide(tool : String) : Decision
      @rules.each do |(pattern, decision)|
        return decision if matches?(pattern, tool)
      end
      Decision::Allow
    end

    # The guarded-pipeline entry point: is this call allowed to proceed?
    def authorize(tool : String, detail : String = "") : Bool
      case decide(tool)
      when .allow?
        true
      when .deny?
        false
      else # ask
        if handler = @ask_handler
          handler.call(tool, detail)
        else
          false # no way to ask -> deny
        end
      end
    end

    private def matches?(pattern : String, tool : String) : Bool
      return true if pattern == "*"
      return tool == pattern unless pattern.includes?('*')
      regex = "^" + Regex.escape(pattern).gsub("\\*", ".*") + "$"
      Regex.new(regex).matches?(tool)
    end
  end
end

Cordis.register("core/approval") do |ctx, config|
  ctx["approval"] = Harness::Approval.from_config(config)
end
