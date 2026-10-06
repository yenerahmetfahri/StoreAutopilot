require "test_helper"

class SummaryTest < Minitest::Test
  include Fixtures

  def test_writes_outcome_steps_and_warnings
    Dir.mktmpdir do |dir|
      path = File.join(dir, "summary.md")
      t = Time.at(1000)
      StoreAutopilot::Summary.write(title: "Release: Version 1.0 (3)", ok: true, steps: [["Checking the stores", t], ["iOS | build", t + 16]],
                                    warnings: ["listing unchanged"], finished_at: t + 16 + 274, path: path)
      text = File.read(path)
      assert_includes text, "### ✅ Release: Version 1.0 (3)"
      assert_includes text, "| Checking the stores | 0:16 |"
      assert_includes text, "| iOS \\| build | 4:34 |"
      assert_includes text, "- listing unchanged"
    end
  end

  def test_nothing_outside_github_actions
    StoreAutopilot::Summary.write(title: "x", ok: true, path: nil)
    StoreAutopilot::Summary.write(title: "x", ok: true, path: "/nonexistent-dir/summary.md") # never raises
  end

  def test_failed_release_is_summarised_with_its_hint
    Dir.mktmpdir do |dir|
      path = File.join(dir, "summary.md")
      ENV["GITHUB_STEP_SUMMARY"] = path
      home = File.join(dir, "home")
      make_secrets(home)
      config = StoreAutopilot::Config.load(make_app(dir))
      shell = FakeShell.new
      shell.on_run do |cmd, env|
        next unless cmd[2] == "status"
        File.write(JSON.parse(File.read(env["STOREAUTOPILOT_JOB"]))["output"], JSON.generate(app: true, live_version: "1.2.3"))
      end
      assert_raises(StoreAutopilot::Error) do
        StoreAutopilot::Pipeline.new(config: config, shell: shell, platforms: [:ios], home: home).release
      end
      text = File.read(path)
      assert_includes text, "### ❌ Release failed"
      assert_includes text, "already live"
      assert_includes text, "→ Raise `version:`"
      assert_includes text, "| Checking the stores |"
    ensure
      ENV.delete("GITHUB_STEP_SUMMARY")
    end
  end
end
