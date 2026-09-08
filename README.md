# Harness

An **everything-is-a-plugin agent harness** for Crystal — the DeepSeek
Harness (`dsh`) concept, rebuilt as a Crystal shard.

An LLM by itself just predicts text. The *harness* is the scaffolding that
turns it into an agent: the loop that feeds model output back in as actions,
the registry of tools it may call, the session log, the permission policy.
The model is the engine; the harness is the rest of the car.

What makes this design unusual is that **there is no privileged core**. The
model adapter, the tool registry, the session log, the approval policy — and
the agent loop itself — are all plugins on a
[Cordis](https://github.com/cordiverse/cordis)-style runtime, composed at
boot from configuration. Every one of them is replaceable without forking
the codebase.

Requires **Crystal >= 1.21.0**. Zero dependencies — stdlib only.

## The runtime: Cordis

Plugins contribute **services**, **typed events**, and **reversible
effects** to a shared context. Mounting a plugin creates a child context;
disposing it unwinds everything the plugin registered.

```crystal
require "harness"

Cordis.register("my/greeter") do |ctx, config|
  ctx["greeter"] = Greeter.new(config["name"].as_s)   # a service
  ctx.on(MyEvent) { |e| puts e.inspect }              # a typed event subscription
  ctx.effect { puts "cleaned up" }                    # a reversible effect
end

root = Cordis::Context.new
child = root.mount("my/greeter", YAML.parse(%({"name": "crystal"})))
child.dispose # greeter, subscription and effect all unwind
```

- **Services** live in one shared registry at the tree root; lookups walk up
  the tree. Registration is an effect — it reverts when its context unloads.
- **Events** are typed (`class MyEvent < Cordis::Event; NAME = "my/event"`),
  emitted on a context and bubbling up to ancestor listeners.
- **Effects** are `Disposable`s, unwound in reverse order.

Because Crystal is statically compiled, plugins are *registered by name at
compile time* (third-party shards call `Cordis.register`) and *selected at
boot time* by configuration rows — the same extension model as a dynamically
loaded tree, minus runtime code loading.

## Profiles, bundles, patches

A running harness is a plugin tree composed at boot from ordered layers:

1. **Bundles** listed by the profile, in order — a bundle is a distribution
   format for config rows (`id` + `plugin` + `config`) and the code they
   mount. The shipped `base` bundle carries the session log, system prompt,
   approval policy, tool registry, built-in tools, model adapter, agent
   registry and agent loop.
2. The profile's inline `rows:`.
3. The profile's `patch:` section.
4. Any `--patch` overlays, in order.

A patch targets a row by id and replaces its config (or its plugin), or
inserts a new row. Whatever a lower layer inserted stays patchable above.

```yaml
# patch.yml — point the harness at a local OpenAI-compatible server
rows:
  - id: llm/llm
    config:
      provider: openai-compatible
      base_url: http://localhost:11434/v1
      model: qwen3
      api_key: unused
```

See the tree your machine boots:

```console
$ dsh --patch patch.yml --dump-config
```

## Run

Build the CLI:

```console
$ shards build dsh
```

Run one task headlessly against DeepSeek:

```console
$ export DEEPSEEK_API_KEY=...
$ ./bin/dsh "Summarize this repository and identify its main packages"
```

The agent can read and edit workspace files, run commands, and report back.
`run_command` and `write_file` are gated behind the approval policy (`ask`
by default); the CLI prompts on stderr.

Or drive it as a library:

```crystal
require "harness"

app = Harness::App.boot("headless", patches: [File.read("patch.yml")])
agent = app.agents.create
puts agent.run("Summarize this repository")
app.dispose
```

## Replace the model from configuration

The agent loop only knows the `Harness::LLM` seam. The shipped providers are
`deepseek` (default), `kimi`, `openai-compatible`, and `mock` — a scripted
adapter for offline runs and tests. Named providers read their key from the
environment (`DEEPSEEK_API_KEY`, `MOONSHOT_API_KEY`/`KIMI_API_KEY`,
`OPENAI_API_KEY`) unless `api_key` is set in config:

```yaml
rows:
  - id: llm/llm
    config:
      provider: kimi           # base URL defaults to https://api.moonshot.ai/v1
      model: kimi-k3           # the default; kimi-k2.7-code, kimi-k2.6, ... also work
      reasoning_effort: low    # optional reasoning control
      prompt_cache_key: sess-1 # optional Kimi prompt-cache bucket
```

```yaml
rows:
  - id: llm/llm
    config:
      provider: mock
      responses:
        - tool_call: {id: "c1", name: "run_command", arguments: "{\"command\":\"ls\"}"}
        - text: "Done."
```

All non-mock providers go through the same `OpenAIAdapter`. It preserves any
path component in `base_url` (e.g. `/v1`), retries with exponential backoff
on 429/5xx responses, network errors, and `insufficient_system_resource`
finishes (`max_retries`, default 3), and round-trips `reasoning_content` on
assistant history — DeepSeek rejects tool-calling history that drops it, and
Kimi's preserved-thinking models expect it verbatim. Cumulative token usage
is exposed as `total_prompt_tokens` / `total_completion_tokens`, and the last
response's `finish_reason` is available for truncation detection. Optional
config knobs: `temperature`, `reasoning_effort`, `thinking`, `prompt_cache_key`,
`user_id`, `max_retries`.

## Replace the agent loop from configuration

Even the driver is a plugin. Swap the `core/agent-loop` row for your own
`Harness::AgentDriver` (plan-act, tree search, multi-agent delegation):

```crystal
Cordis.register("my/plan-act-loop") do |ctx, config|
  ctx["agentLoop"] = PlanActDriver.new(ctx)
end
```

```yaml
rows:
  - id: core/agent-loop
    plugin: my/plan-act-loop
```

## Events

- **Session events** (`session/event`) are durable facts appended to the
  log — messages, tool calls, tool results. Use one when the fact must
  survive a reload; set `persist: path.jsonl` on the `core/session` row.
- **Agent events** (`agent/start`, `agent/message`, `agent/tool-call`,
  `agent/finish`) carry the live `Agent` and are not persisted.

```crystal
app.root.on(Harness::AgentToolCall) { |e| puts "-> #{e.call.name}" }
app.root.on(Harness::SessionEvent)  { |e| log e }
```

## Built-in tools

| Tool             | Default policy | Notes                      |
|------------------|----------------|----------------------------|
| `read_file`      | allow          | Workspace-confined         |
| `list_directory` | allow          | Workspace-confined         |
| `write_file`     | ask            | Workspace-confined         |
| `run_command`    | ask            | Runs in the workspace root |

Workspace confinement is the lightweight sandbox boundary: paths resolve
against the workspace root and escapes are rejected. The approval policy is
ordered `tool -> allow|ask|deny` rules with `*` globs; `ask` resolves
through a handler you install (a UI prompt, a callback, or safe-deny when
absent).

## Concept map

| DeepSeek Harness (TypeScript)               | This shard (Crystal)                                                   |
|---------------------------------------------|------------------------------------------------------------------------|
| Cordis context / plugin tree                | `Cordis::Context`, `Cordis.register`                                   |
| Reversible effects                          | `Cordis::Disposable`, `ctx.effect`, `ctx.own`                          |
| Services (`ctx.sessions`, `ctx.tools`, ...) | `ctx["sessions"] = ...`, `ctx.service("tools", Tools)`                 |
| `session/event`, `agent/*` events           | `Harness::SessionEvent`, `Harness::AgentStart/Message/ToolCall/Finish` |
| Bundles (`dsh-base`)                        | `Harness::Bundles::BASE` (`src/harness/bundles/base.yml`)              |
| Profiles (`web`, `headless`, ...)           | `headless` template + profile YAML files                               |
| `cordis.patch.yml`                          | Patch YAML via `--patch` / `App.boot(patches:)`                        |
| `dsh --dump-config`                         | `dsh --dump-config`                                                    |
| `llm` adapter seam                          | `Harness::LLM` (`OpenAIAdapter`, `MockAdapter`)                        |
| Scoped tool registry + guarded pipeline     | `Harness::Tools#register(scope:)` / `#execute`                         |
| Sandbox & approval policy                   | Workspace confinement + `Harness::Approval`                            |
| Dynamic plugin loading                      | Compile-time registration (Crystal is static)                          |

Deliberately out of scope (upstream has them; this shard is the core
library): the web UI, the TypeScript/Python SDK servers, ACP, telemetry and
webhooks.

## Develop

```console
$ crystal spec          # 56 examples
$ crystal tool format
$ shards build dsh
```

## Safety

This software can execute model-generated commands and modify files. The
approval policy and workspace confinement reduce risk but do not guarantee
isolation. Run with the least privileges required, prefer a disposable
environment, keep backups, and review proposed commands before allowing
them. Provided without warranty under the MIT License.
