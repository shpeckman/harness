# src/harness/composition.cr
require "yaml"
require "./config_access"

module Harness
  # One config row: mount `plugin` under `id` with `config`.
  class Row
    getter id       : String
    property plugin : String
    property config : YAML::Any

    def initialize(@id : String, @plugin : String, @config : YAML::Any = YAML::Any.new(nil))
    end

    def self.parse(yaml : YAML::Any) : Row
      id     = Cfg.str(yaml, "id") || raise ArgumentError.new("config row missing \"id\"")
      plugin = Cfg.str(yaml, "plugin") || raise ArgumentError.new("config row #{id.inspect} missing \"plugin\"")
      new(id, plugin, Cfg.get(yaml, "config") || YAML::Any.new(nil))
    end
  end

  # A running harness is a plugin tree composed at boot from ordered layers:
  #
  #   1. each bundle listed by the profile, in order (a bundle is a
  #      distribution format for config rows and the code they mount),
  #   2. the profile's own inline rows,
  #   3. the profile's `patch:` section,
  #   4. any `--patch` overlays, in order.
  #
  # A patch targets a row by id and replaces its config (and optionally its
  # plugin), or inserts a new row. Whatever a lower layer inserted stays
  # patchable by the layers above it.
  class Composition
    getter rows = [] of Row

    def initialize(@rows : Array(Row))
    end

    # Load a profile by shipped name ("headless") or by path to a YAML file,
    # then apply any patch overlays (file contents already read).
    def self.load(profile : String = "headless", patches : Array(String) = [] of String) : Composition
      text = Bundles.profile?(profile)
      text ||= File.read(profile) if File.exists?(profile)
      text ||= raise ArgumentError.new("unknown profile #{profile.inspect} (not a shipped profile or a file)")
      compose(text.not_nil!, patches)
    end

    # Compose from raw profile YAML plus raw patch YAML strings.
    def self.compose(profile_yaml : String, patch_yamls : Array(String) = [] of String) : Composition
      doc  = YAML.parse(profile_yaml)
      rows = [] of Row

      if bundles = Cfg.dig(doc, "dsh", "profile", "bundles").try(&.as_a?)
        bundles.each do |entry|
          name = entry.as_s
          text = Bundles.bundle?(name)
          text ||= File.read(name) if File.exists?(name)
          text ||= raise ArgumentError.new("unknown bundle #{name.inspect} (not a shipped bundle or a file)")
          bundle_rows = Cfg.arr(YAML.parse(text.not_nil!), "rows") ||
                        raise ArgumentError.new("bundle #{name.inspect} has no \"rows\"")
          bundle_rows.each { |row| rows << Row.parse(row) }
        end
      end

      if inline = Cfg.arr(doc, "rows")
        inline.each { |row| rows << Row.parse(row) }
      end

      if patch = Cfg.get(doc, "patch")
        apply_patch(rows, patch)
      end

      patch_yamls.each { |patch_yaml| apply_patch(rows, YAML.parse(patch_yaml)) }

      new(rows)
    end

    # Apply one patch document to the row list.
    def self.apply_patch(rows : Array(Row), patch : YAML::Any) : Nil
      list = Cfg.arr(patch, "rows") || return
      list.each do |entry|
        id = Cfg.str(entry, "id") || raise ArgumentError.new("patch row missing \"id\"")
        if existing = rows.find { |row| row.id == id }
          if plugin = Cfg.str(entry, "plugin")
            existing.plugin = plugin
          end
          if config = Cfg.get(entry, "config")
            existing.config = config
          end
        else
          plugin = Cfg.str(entry, "plugin") ||
                   raise ArgumentError.new("patch inserts new row #{id.inspect} without a \"plugin\"")
          rows << Row.new(id, plugin, Cfg.get(entry, "config") || YAML::Any.new(nil))
        end
      end
    end

    # The `dsh --dump-config` view: the final ordered rows any layer produced.
    def dump : String
      any_rows = rows.map do |row|
        mapping = {} of YAML::Any => YAML::Any
        mapping[YAML::Any.new("id")] = YAML::Any.new(row.id)
        mapping[YAML::Any.new("plugin")] = YAML::Any.new(row.plugin)
        mapping[YAML::Any.new("config")] = row.config unless row.config.raw.nil?
        YAML::Any.new(mapping)
      end
      YAML::Any.new({YAML::Any.new("rows") => YAML::Any.new(any_rows)}).to_yaml
    end
  end
end
