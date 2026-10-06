require "test_helper"

class UITest < Minitest::Test
  UI = StoreAutopilot::UI

  def setup = UI.out = (@out = StringIO.new)
  def teardown = UI.close_log

  def test_log_mirrors_screen_and_command_output_privately
    Dir.mktmpdir do |dir|
      UI.start_log(dir, "release")
      UI.step("Building")
      UI.ok("done")
      UI.output("child line\n")
      UI.log_only("backtrace here")
      path = UI.log_path
      UI.close_log
      log = File.read(path)
      assert_match(/▶ Building  \[\d\d:\d\d:\d\d\]/, log)
      assert_includes log, "✓ done"
      assert_includes log, "child line"
      assert_includes log, "backtrace here"
      refute_includes @out.string, "backtrace here"
      assert_equal 0o600, File.stat(path).mode & 0o777
      assert_equal 0o700, File.stat(dir).mode & 0o777
    end
  end

  def test_error_points_to_the_log
    Dir.mktmpdir do |dir|
      UI.start_log(dir, "submit")
      UI.error(StoreAutopilot::Error.new("Upload failed", hint: "Check the key"))
      assert_includes @out.string, "✗ Upload failed"
      assert_includes @out.string, "→ Check the key"
      assert_includes @out.string, "Log: #{UI.log_path}"
    end
  end

  def test_keeps_only_recent_logs
    Dir.mktmpdir do |dir|
      40.times { |i| FileUtils.touch(File.join(dir, format("20260101-0000%02d-x.log", i))) }
      UI.start_log(dir, "doctor")
      assert_equal UI::KEEP_LOGS, Dir.glob(File.join(dir, "*.log")).size
      refute File.exist?(File.join(dir, "20260101-000000-x.log"))
    end
  end

  def test_unwritable_log_dir_is_only_a_warning
    Dir.mktmpdir do |dir|
      blocker = File.join(dir, "file")
      File.write(blocker, "")
      UI.start_log(File.join(blocker, "logs"), "doctor")
      assert_nil UI.log_path
      assert_includes @out.string, "could not write a log file"
    end
  end
end
