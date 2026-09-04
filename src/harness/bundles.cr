# src/harness/bundles.cr
module Harness
  # The shipped bundles and profile templates, embedded at compile time so
  # the shard works from any install location.
  module Bundles
    BASE             = {{ read_file("#{__DIR__}/bundles/base.yml") }}
    HEADLESS_PROFILE = {{ read_file("#{__DIR__}/bundles/headless.yml") }}

    # A shipped bundle's YAML by name, or nil.
    def self.bundle?(name : String) : String?
      case name
      when "base" then BASE
      end
    end

    # A shipped profile template's YAML by name, or nil.
    def self.profile?(name : String) : String?
      case name
      when "headless" then HEADLESS_PROFILE
      end
    end
  end
end
