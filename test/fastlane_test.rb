require "test_helper"

class FastlaneTest < Minitest::Test
  def test_lane_writes_job_runs_fastlane_and_reads_output
    Dir.mktmpdir do |work|
      shell = FakeShell.new
      shell.on_run do |_cmd, env|
        job = JSON.parse(File.read(env["STOREAUTOPILOT_JOB"]))
        File.write(job["output"], JSON.generate(build_number: 41))
      end
      out = StoreAutopilot::Fastlane.new(shell: shell, workdir: work).lane(:ios, :status, { bundle_id: "com.x" })
      assert_equal %w[fastlane ios status], shell.runs.first
      assert_equal 41, out["build_number"]
      assert_equal 0o600, File.stat(File.join(work, "job.json")).mode & 0o777
    end
  end

  def test_quiet_lane_keeps_output_off_screen_and_explains_a_crash
    Dir.mktmpdir do |work|
      shell = FakeShell.new("fastlane ios status" => "lots of fastlane output\n")
      StoreAutopilot::UI.out = (out = StringIO.new)
      err = assert_raises(StoreAutopilot::Error) do
        StoreAutopilot::Fastlane.new(shell: shell, workdir: work).lane(:ios, :status, {}, quiet: true)
      end
      assert_includes err.message, "fastlane ios status failed"
      refute_includes out.string, "lots of fastlane output"
    end
  end

  # Fails once, then works: the lane is run again.
  def test_retries_a_failed_lane
    Dir.mktmpdir do |work|
      calls = 0
      shell = FakeShell.new
      shell.on_run do |_cmd, env|
        calls += 1
        raise StoreAutopilot::Error, "503 Service Unavailable" if calls == 1
        File.write(JSON.parse(File.read(env["STOREAUTOPILOT_JOB"]))["output"], JSON.generate(ok: true))
      end
      StoreAutopilot::UI.out = (out = StringIO.new)
      result = StoreAutopilot::Fastlane.new(shell: shell, workdir: work, retry_delay: 0).lane(:ios, :metadata, {}, retries: 1)
      assert_equal({ "ok" => true }, result)
      assert_includes out.string, "503 Service Unavailable — trying again"
    end
  end

  def test_error_results_are_retried_then_returned
    Dir.mktmpdir do |work|
      shell = FakeShell.new
      shell.on_run { |_cmd, env| File.write(JSON.parse(File.read(env["STOREAUTOPILOT_JOB"]))["output"], JSON.generate(error: "timeout")) }
      result = StoreAutopilot::Fastlane.new(shell: shell, workdir: work, retry_delay: 0).lane(:ios, :status, {}, retries: 2)
      assert_equal "timeout", result["error"]
      assert_equal 3, shell.runs.size
    end
  end

  def test_no_retries_by_default
    Dir.mktmpdir do |work|
      shell = FakeShell.new
      shell.on_run { |*| raise StoreAutopilot::Error, "upload failed" }
      assert_raises(StoreAutopilot::Error) { StoreAutopilot::Fastlane.new(shell: shell, workdir: work, retry_delay: 0).lane(:ios, :upload, {}) }
      assert_equal 1, shell.runs.size
    end
  end

  def test_fastfile_is_valid_ruby
    assert system("ruby", "-c", File.join(StoreAutopilot::ROOT, "fastlane", "Fastfile"), out: File::NULL)
  end

  PERMISSION_DENIED = "Google Api Error: forbidden: The caller does not have permission"

  def test_a_denied_play_call_names_the_permission_it_needs
    Dir.mktmpdir do |work|
      shell = FakeShell.new
      shell.on_run { raise StoreAutopilot::Error.new("Command failed (exit 1): fastlane android upload", output: PERMISSION_DENIED) }
      err = assert_raises(StoreAutopilot::Error) do
        StoreAutopilot::Fastlane.new(shell: shell, workdir: work).lane(:android, :upload, { "track" => "internal" })
      end
      assert_includes err.hint, "Release apps to testing tracks"
      assert_includes err.hint, "service account"
    end
  end

  def test_a_denied_play_result_gets_the_same_explanation
    Dir.mktmpdir do |work|
      shell = FakeShell.new
      shell.on_run { |_cmd, env| File.write(JSON.parse(File.read(env["STOREAUTOPILOT_JOB"]))["output"], JSON.generate(error: PERMISSION_DENIED)) }
      result = StoreAutopilot::Fastlane.new(shell: shell, workdir: work).lane(:android, :status, {})
      assert_includes result["error"], "View app information"
    end
  end

  def test_other_errors_are_left_alone
    Dir.mktmpdir do |work|
      shell = FakeShell.new
      shell.on_run { raise StoreAutopilot::Error.new("Command failed", hint: "See the output above.", output: "boom") }
      err = assert_raises(StoreAutopilot::Error) { StoreAutopilot::Fastlane.new(shell: shell, workdir: work).lane(:android, :upload, {}) }
      assert_equal "See the output above.", err.hint
    end
  end
end
