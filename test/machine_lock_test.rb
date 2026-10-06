require "test_helper"

class MachineLockTest < Minitest::Test
  L = StoreAutopilot::MachineLock

  def setup = StoreAutopilot::UI.out = (@out = StringIO.new)

  # Another process (another app's release) holds the lock for a moment; this one waits, then runs.
  def test_second_run_waits_for_the_first
    Dir.mktmpdir do |home|
      ready = File.join(home, "ready")
      child = fork do
        L.new(home: home, app_id: "app-one", what: "release").hold { FileUtils.touch(ready); sleep 1.2 }
        exit!(0)
      end
      sleep 0.05 until File.exist?(ready)
      started = Time.now
      ran = false
      L.new(home: home, app_id: "app-two", what: "release", poll: 0.1).hold { ran = true }
      Process.wait(child)
      assert ran
      assert_operator Time.now - started, :>=, 0.8
      assert_includes @out.string, "busy with app-one's release"
    end
  end

  # A run that dies while holding the lock doesn't block the next one.
  def test_a_crashed_run_frees_the_lock
    Dir.mktmpdir do |home|
      child = fork { L.new(home: home, app_id: "app-one", what: "release").hold { exit!(1) } }
      Process.wait(child)
      ran = false
      L.new(home: home, app_id: "app-two", what: "release", poll: 0.1).hold { ran = true }
      assert ran
      refute_includes @out.string, "Waiting"
    end
  end

  def test_gives_up_after_the_wait_limit
    Dir.mktmpdir do |home|
      ready = File.join(home, "ready")
      child = fork { L.new(home: home, app_id: "app-one", what: "release").hold { FileUtils.touch(ready); sleep 3 } }
      sleep 0.05 until File.exist?(ready)
      err = assert_raises(StoreAutopilot::Error) { L.new(home: home, app_id: "two", what: "release", wait: 0.3, poll: 0.1).hold { nil } }
      assert_includes err.message, "app-one"
    ensure
      Process.kill("KILL", child) rescue nil
      Process.wait(child) rescue nil
    end
  end
end
