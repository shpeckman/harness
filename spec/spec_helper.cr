# spec/spec_helper.cr
require "spec"
require "file_utils"
require "../src/harness"

# Patch overlay that swaps the model adapter for the scripted mock — the
# canonical proof that the LLM is replaceable from configuration.
MOCK_LLM_PATCH = <<-YAML
rows:
  - id: llm/llm
    config:
      provider: mock
YAML

# Boot the shipped headless profile with the mock model mounted.
def boot_mock_app(patches : Array(String) = [] of String) : Harness::App
  composition = Harness::Composition.compose(
    Harness::Bundles::HEADLESS_PROFILE,
    [MOCK_LLM_PATCH] + patches
  )
  Harness::App.boot(composition)
end

# A throwaway workspace directory for filesystem-tool specs.
def with_temp_workspace(& : String ->) : Nil
  dir = File.join(Dir.tempdir, "harness-spec-#{Random::Secure.hex(6)}")
  Dir.mkdir_p(dir)
  begin
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end
