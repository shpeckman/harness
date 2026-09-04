# src/harness/app.cr
require "./composition"

module Harness
  # A booted harness: the root of the plugin tree plus the composition that
  # produced it. `App.boot` mounts every composed row in order; `dispose`
  # unwinds the whole tree.
  class App
    getter root        : Cordis::Context
    getter composition : Composition

    def initialize(@root : Cordis::Context, @composition : Composition)
    end

    def self.boot(profile : String = "headless", patches : Array(String) = [] of String) : App
      boot(Composition.load(profile, patches))
    end

    def self.boot(composition : Composition) : App
      root = Cordis::Context.new
      composition.rows.each { |row| root.mount(row.plugin, row.config) }
      new(root, composition)
    end

    # Convenience accessors for the core services.
    def agents : Agents
      root.service("agents", Agents)
    end

    def tools : Tools
      root.service("tools", Tools)
    end

    def sessions : Sessions
      root.service("sessions", Sessions)
    end

    def llm : LLM
      root.service("llm", LLM)
    end

    def dispose : Nil
      root.dispose
    end
  end
end
