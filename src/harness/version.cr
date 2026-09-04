# src/harness/version.cr
module Harness
  VERSION = {{ `shards version "#{__DIR__}"`.chomp.stringify }}
end
