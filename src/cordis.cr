# src/cordis.cr
require "yaml"
require "./cordis/disposable"
require "./cordis/event"
require "./cordis/service"
require "./cordis/context"

# Cordis is the framework under Harness: plugins contribute services, typed
# events, and reversible effects to a shared context. Every part of the
# product is a plugin — including the model adapter, the tool registry, the
# session log, and the agent loop itself — so each is replaceable from
# configuration.
#
# There is no privileged core to patch: you extend Harness by mounting a
# plugin beside the others, and registrations are effects that unwind when
# their plugin unloads.
#
# Because Crystal is statically compiled, plugins are registered by name at
# compile time (third-party shards call `Cordis.register`) and selected at
# boot time by configuration rows — the same extension model as a dynamically
# loaded tree, minus runtime code loading.
module Cordis
  # A plugin factory. Receives the mounting context (a child of the mounter)
  # and the plugin's config row. Everything the factory registers on the
  # context unwinds when that context is disposed.
  alias Factory = Context, YAML::Any -> Nil

  @@registry = {} of String => Factory

  # Register a plugin under a name, e.g. `"core/tools"`.
  def self.register(name : String, &block : Factory) : Nil
    if @@registry.has_key?(name)
      raise ArgumentError.new("plugin #{name.inspect} is already registered")
    end
    @@registry[name] = block
  end

  # Look up a registered plugin factory by name.
  def self.plugin?(name : String) : Factory?
    @@registry[name]?
  end

  # All registered plugin names, sorted.
  def self.plugin_names : Array(String)
    @@registry.keys.sort!
  end
end
