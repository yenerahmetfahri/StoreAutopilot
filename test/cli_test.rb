require "test_helper"

class CLITest < Minitest::Test
  def setup = StoreAutopilot::UI.out = (@out = StringIO.new)

  def test_help_prints_usage_and_succeeds
    assert_equal 0, StoreAutopilot::CLI.start(["--help"])
    assert_includes @out.string, "Usage: storeautopilot"
  end

  def test_version
    assert_equal 0, StoreAutopilot::CLI.start(["--version"])
    assert_equal "storeautopilot #{StoreAutopilot::VERSION}\n", @out.string
  end

  def test_unknown_command_fails_with_usage
    assert_equal 1, StoreAutopilot::CLI.start(["nope"])
    assert_includes @out.string, "Unknown command: nope"
  end

  def test_bad_option_fails_with_hint
    assert_equal 1, StoreAutopilot::CLI.start(["release", "--only", "windows"])
    assert_includes @out.string, "storeautopilot --help"
  end
end

class CLIErrorTest < Minitest::Test
  def setup = StoreAutopilot::UI.out = (@out = StringIO.new)

  # Runs `storeautopilot doctor` with the command replaced by block; returns the exit code.
  def with_command(&block)
    StoreAutopilot::Commands.singleton_class.alias_method(:orig_doctor, :doctor)
    StoreAutopilot::Commands.define_singleton_method(:doctor, &block)
    StoreAutopilot::CLI.start(["doctor"])
  ensure
    StoreAutopilot::Commands.singleton_class.alias_method(:doctor, :orig_doctor)
  end

  def test_unexpected_error_is_shown_briefly_and_logged_in_full
    assert_equal 1, with_command { |*| raise NoMethodError, "undefined method `x' for nil" }
    assert_includes @out.string, "Unexpected error: NoMethodError"
    assert_includes @out.string, "report it"
    log = File.read(@out.string[/Log: (\S+)/, 1])
    assert_includes log, "cli_test.rb" # backtrace
    refute_includes @out.string, "cli_test.rb"
  end

  def test_ctrl_c_is_a_clean_cancel
    assert_equal 130, with_command { |*| raise Interrupt }
    assert_includes @out.string, "Cancelled."
  end

  def test_each_command_writes_a_log
    with_command { |*| StoreAutopilot::UI.ok("all good") }
    log = Dir.glob(File.join(ENV["STOREAUTOPILOT_LOG_DIR"], "*-doctor-*.log")).max_by { |f| File.mtime(f) }
    assert_includes File.read(log), "all good"
  end
end
