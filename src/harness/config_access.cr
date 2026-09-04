# src/harness/config_access.cr
require "yaml"

module Harness
  # Safe accessors for `YAML::Any` config rows. `YAML::Any#[]` assumes a
  # mapping; these helpers return nil instead of raising when the shape is
  # wrong, which keeps plugin config code terse.
  module Cfg
    # Fetch `key` from a mapping, or nil when absent / not a mapping.
    def self.get(config : YAML::Any, key : String) : YAML::Any?
      raw = config.raw
      return nil unless raw.is_a?(Hash(YAML::Any, YAML::Any))
      raw[YAML::Any.new(key)]?
    end

    # Dig through nested mappings: `Cfg.dig(doc, "dsh", "profile", "bundles")`.
    def self.dig(config : YAML::Any, *keys : String) : YAML::Any?
      current = config
      keys.each do |key|
        return nil unless value = get(current, key)
        current = value
      end
      current
    end

    # String value or nil.
    def self.str(config : YAML::Any, key : String) : String?
      get(config, key).try(&.as_s?)
    end

    # Int value or nil.
    def self.int(config : YAML::Any, key : String) : Int32?
      get(config, key).try(&.as_i?)
    end

    # Array value or nil.
    def self.arr(config : YAML::Any, key : String) : Array(YAML::Any)?
      get(config, key).try(&.as_a?)
    end
  end
end
