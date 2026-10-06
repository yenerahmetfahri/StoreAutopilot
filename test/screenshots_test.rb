require "test_helper"

class ScreenshotsTest < Minitest::Test
  include Fixtures

  class FakeDevice
    def initialize(id) = @id = id
    def boot = @id
  end

  def write_flutter_files(config)
    [StoreAutopilot::Screenshots::TEST, StoreAutopilot::Screenshots::DRIVER].each do |rel|
      path = File.join(config.flutter_dir, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "// test")
    end
  end

  def test_runs_flutter_drive_per_locale_and_checks_output
    Dir.mktmpdir do |dir|
      config = StoreAutopilot::Config.load(make_app(dir))
      write_flutter_files(config)
      shell = FakeShell.new
      shell.on_run do |cmd, env|
        next unless cmd.first == "flutter"
        config.screenshots.each { |s| File.write(File.join(env["STORE_SHOTS_DIR"], "#{s}.png"), "png") }
      end
      shots = StoreAutopilot::Screenshots.new(config: config, shell: shell, devices: { ios: FakeDevice.new("SIM") })
      shots.capture(:ios, File.join(dir, "raw"))
      cmd = shell.runs.first
      assert_equal %w[flutter drive], cmd.first(2)
      assert_includes cmd, "--dart-define=STORE_LOCALE=en"
      assert_includes cmd, "--dart-define=STORE_PLATFORM=ios"
      assert_equal "SIM", cmd[cmd.index("-d") + 1]
      assert File.file?(File.join(dir, "raw", "ios", "en", "02_play.png"))
    end
  end

  def test_ipad_runs_as_ios_tablet_and_shuts_its_simulator_down
    Dir.mktmpdir do |dir|
      config = StoreAutopilot::Config.load(make_app(dir))
      write_flutter_files(config)
      shell = FakeShell.new
      shell.on_run { |_cmd, env| config.screenshots.each { |s| File.write(File.join(env["STORE_SHOTS_DIR"], "#{s}.png"), "png") } }
      ipad = FakeDevice.new("PAD")
      ipad.define_singleton_method(:shutdown) { @down = true }
      StoreAutopilot::Screenshots.new(config: config, shell: shell, devices: { ipad: ipad }).capture(:ipad, File.join(dir, "raw"))
      cmd = shell.runs.first
      assert_includes cmd, "--dart-define=STORE_PLATFORM=ios"
      assert_includes cmd, "--dart-define=STORE_DEVICE=tablet"
      assert File.file?(File.join(dir, "raw", "ipad", "en", "01_home.png"))
      assert ipad.instance_variable_get(:@down)
    end
  end

  def test_missing_capture_is_reported
    Dir.mktmpdir do |dir|
      config = StoreAutopilot::Config.load(make_app(dir))
      write_flutter_files(config)
      shots = StoreAutopilot::Screenshots.new(config: config, shell: FakeShell.new, devices: { ios: FakeDevice.new("SIM") })
      err = assert_raises(StoreAutopilot::Error) { shots.capture(:ios, File.join(dir, "raw")) }
      assert_includes err.message, "01_home"
    end
  end

  def test_missing_test_files_are_reported
    Dir.mktmpdir do |dir|
      config = StoreAutopilot::Config.load(make_app(dir))
      shots = StoreAutopilot::Screenshots.new(config: config, shell: FakeShell.new, devices: {})
      assert_equal 2, shots.missing_files.size
      err = assert_raises(StoreAutopilot::Error) { shots.capture(:ios, dir) }
      assert_includes err.hint, "storeautopilot init"
    end
  end
end
