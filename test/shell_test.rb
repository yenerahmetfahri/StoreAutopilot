require "test_helper"

class ShellTest < Minitest::Test
  def test_capture_returns_stdout
    assert_equal "hi\n", StoreAutopilot::Shell.new.capture("echo", "hi")
  end

  def test_run_raises_error_on_failure
    err = assert_raises(StoreAutopilot::Error) { StoreAutopilot::Shell.new.run("false") }
    assert_includes err.message, "Command failed (exit 1): false"
  end

  def test_capture_allow_failure_returns_output
    assert_equal "", StoreAutopilot::Shell.new.capture("false", allow_failure: true)
  end

  def test_env_is_passed
    assert_equal "1\n", StoreAutopilot::Shell.new(env: { "SA_X" => "1" }).capture("sh", "-c", "echo $SA_X")
  end
end

class ShellTimeoutTest < Minitest::Test
  def test_capture_times_out
    started = Time.now
    err = assert_raises(StoreAutopilot::Error) { StoreAutopilot::Shell.new.capture("sleep", "5", timeout: 0.5) }
    assert_includes err.message, "timed out"
    assert_operator Time.now - started, :<, 3
  end
end

class ShellRunTest < Minitest::Test
  def setup = StoreAutopilot::UI.out = (@out = StringIO.new)

  def test_run_streams_stdout_and_stderr
    StoreAutopilot::Shell.new.run("sh", "-c", "echo out; echo err >&2")
    assert_includes @out.string, "out\n"
    assert_includes @out.string, "err\n"
  end

  def test_run_reports_exit_code
    err = assert_raises(StoreAutopilot::Error) { StoreAutopilot::Shell.new.run("sh", "-c", "exit 3") }
    assert_includes err.message, "exit 3"
  end

  def test_run_explains_a_missing_program
    err = assert_raises(StoreAutopilot::Error) { StoreAutopilot::Shell.new.run("storeautopilot-no-such-tool") }
    assert_includes err.message, "Could not start storeautopilot-no-such-tool"
    assert_includes err.hint, "doctor"
  end

  def test_capture_explains_a_missing_program
    err = assert_raises(StoreAutopilot::Error) { StoreAutopilot::Shell.new.capture("storeautopilot-no-such-tool") }
    assert_includes err.message, "Could not start"
  end

  # An unattended run must not hang on a prompt.
  def test_run_gives_the_command_no_input
    StoreAutopilot::Shell.new.run("sh", "-c", "read answer || echo no-input")
    assert_includes @out.string, "no-input"
  end

  def test_failure_message_never_contains_later_arguments
    err = assert_raises(StoreAutopilot::Error) { StoreAutopilot::Shell.new.run("sh", "-c", "exit 1", "--token", "SECRET") }
    refute_includes err.message, "SECRET"
  end
end

class ShellIdleTest < Minitest::Test
  def setup = StoreAutopilot::UI.out = StringIO.new

  def test_silent_command_is_stopped
    started = Time.now
    err = assert_raises(StoreAutopilot::Error) { StoreAutopilot::Shell.new(idle_timeout: 1).run("sleep", "30") }
    assert_includes err.message, "No output for 1s"
    assert_operator Time.now - started, :<, 6
  end

  # Children started by the command are stopped too, not left running.
  def test_stopping_takes_the_whole_process_group
    Dir.mktmpdir do |dir|
      marker = File.join(dir, "child-finished")
      assert_raises(StoreAutopilot::Error) do
        StoreAutopilot::Shell.new(idle_timeout: 1).run("sh", "-c", "(sleep 2; touch #{marker}) & wait")
      end
      sleep 2.5
      refute File.exist?(marker)
    end
  end

  def test_a_chatty_command_may_run_longer_than_the_idle_limit
    StoreAutopilot::Shell.new(idle_timeout: 1).run("sh", "-c", "for i in 1 2 3; do echo tick; sleep 0.6; done")
  end
end
