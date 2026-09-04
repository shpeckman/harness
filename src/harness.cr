# src/harness.cr
require "./cordis"
require "./harness/version"
require "./harness/config_access"
require "./harness/message"
require "./harness/llm"
require "./harness/events"
require "./harness/llm/mock"
require "./harness/llm/openai"
require "./harness/core/session"
require "./harness/core/system_prompt"
require "./harness/core/approval"
require "./harness/core/tools"
require "./harness/core/agent"
require "./harness/core/agent_loop"
require "./harness/tools/fs"
require "./harness/tools/shell"
require "./harness/bundles"
require "./harness/composition"
require "./harness/app"

# Harness is an everything-is-a-plugin agent harness: a Cordis-style plugin
# runtime where the model adapter, tool registry, session log, approval
# policy and the agent loop itself are all replaceable plugins, composed at
# boot from profiles, bundles and patches.
#
# Quick start (library):
#
#     require "harness"
#
#     app = Harness::App.boot("headless")
#     agent = app.agents.create
#     puts agent.run("Summarize this repository")
#     app.dispose
#
# Set DEEPSEEK_API_KEY, or patch the `llm/llm` row to point at any
# OpenAI-compatible endpoint — or at `provider: mock` for offline runs.
module Harness
end
