# spec/composition_spec.cr
require "./spec_helper"

describe Harness::Composition do
  it "loads the shipped base bundle rows in order" do
    composition = Harness::Composition.compose(Harness::Bundles::HEADLESS_PROFILE)
    composition.rows.map(&.id).should eq [
      "core/session",
      "core/system-prompt",
      "core/approval",
      "core/tools",
      "tools/fs",
      "tools/shell",
      "llm/llm",
      "core/agent",
      "core/agent-loop",
    ]
  end

  it "replaces a row's whole config when a patch targets its id" do
    composition = Harness::Composition.compose(Harness::Bundles::HEADLESS_PROFILE, [MOCK_LLM_PATCH])
    row         = composition.rows.find { |r| r.id == "llm/llm" }.not_nil!
    Harness::Cfg.str(row.config, "provider").should eq "mock"
    Harness::Cfg.str(row.config, "model").should be_nil # whole config replaced
  end

  it "keeps the row's position when patched" do
    composition = Harness::Composition.compose(Harness::Bundles::HEADLESS_PROFILE, [MOCK_LLM_PATCH])
    composition.rows.map(&.id).index("llm/llm").should eq 6
  end

  it "inserts new rows from a patch" do
    patch = <<-YAML
    rows:
      - id: spec/extra
        plugin: core/session
        config: {}
    YAML
    composition = Harness::Composition.compose(Harness::Bundles::HEADLESS_PROFILE, [patch])
    composition.rows.last.id.should eq "spec/extra"
  end

  it "applies overlays in order, later layers winning" do
    first = <<-YAML
    rows:
      - id: core/agent-loop
        config:
          max_turns: 10
    YAML
    second = <<-YAML
    rows:
      - id: core/agent-loop
        config:
          max_turns: 3
    YAML
    composition = Harness::Composition.compose(Harness::Bundles::HEADLESS_PROFILE, [first, second])
    row         = composition.rows.find { |r| r.id == "core/agent-loop" }.not_nil!
    Harness::Cfg.int(row.config, "max_turns").should eq 3
  end

  it "supports a profile-level patch section" do
    profile = <<-YAML
    dsh:
      profile:
        bundles: [base]
    patch:
      rows:
        - id: llm/llm
          config:
            provider: mock
    YAML
    composition = Harness::Composition.compose(profile)
    row         = composition.rows.find { |r| r.id == "llm/llm" }.not_nil!
    Harness::Cfg.str(row.config, "provider").should eq "mock"
  end

  it "refuses to insert a patch row without a plugin" do
    patch = %(rows:\n  - {id: "nope", config: {}})
    expect_raises(ArgumentError, /without a "plugin"/) do
      Harness::Composition.compose(Harness::Bundles::HEADLESS_PROFILE, [patch])
    end
  end

  it "dumps the composed rows as reparseable YAML" do
    composition = Harness::Composition.compose(Harness::Bundles::HEADLESS_PROFILE, [MOCK_LLM_PATCH])
    parsed      = YAML.parse(composition.dump)
    rows        = parsed["rows"].as_a
    rows.size.should eq 9
    llm_row = rows.find { |r| r["id"].as_s == "llm/llm" }.not_nil!
    llm_row["config"]["provider"].as_s.should eq "mock"
  end

  it "raises for unknown profiles and bundles" do
    expect_raises(ArgumentError, /unknown profile/) { Harness::Composition.load("nope") }
    expect_raises(ArgumentError, /unknown bundle/) do
      Harness::Composition.compose(%(dsh:\n  profile:\n    bundles: [nope]))
    end
  end
end

describe Harness::App do
  it "boots the full headless profile with the mock model" do
    app = boot_mock_app
    app.llm.should be_a Harness::MockAdapter
    app.tools.names.should contain "read_file"
    app.tools.names.should contain "run_command"
    app.agents.size.should eq 0
    app.dispose
  end

  it "fails to boot when a row names an unregistered plugin" do
    profile = %(rows:\n  - {id: "x", plugin: "nope/nope", config: {}})
    expect_raises(ArgumentError, /unknown plugin/) do
      Harness::App.boot(Harness::Composition.compose(profile))
    end
  end

  it "unwinds the whole tree on dispose" do
    app  = boot_mock_app
    root = app.root
    app.dispose
    root.disposed?.should be_true
    expect_raises(Exception, /disposed/) { root.mount("core/session") }
  end
end
