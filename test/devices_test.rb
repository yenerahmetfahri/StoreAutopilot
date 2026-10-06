require "test_helper"

class DevicesTest < Minitest::Test
  RUNTIMES = JSON.generate(runtimes: [
    { platform: "iOS", version: "26.0", identifier: "rt.26" },
    { platform: "iOS", version: "27.0", identifier: "rt.27" }
  ])

  def test_ios_reuses_existing_simulator
    devices = JSON.generate(devices: { "rt.27" => [{ name: StoreAutopilot::IosSimulator::NAME, udid: "U1" }] })
    shell = FakeShell.new("list devices" => devices, "simctl boot" => "", "bootstatus" => "", "status_bar" => "")
    assert_equal "U1", StoreAutopilot::IosSimulator.new(shell).boot
    refute(shell.captures.any? { |c| c.include?("create") })
  end

  def test_ios_creates_simulator_on_newest_runtime
    shell = FakeShell.new("list devices" => JSON.generate(devices: {}), "list runtimes" => RUNTIMES,
                          "simctl create" => "U2\n", "simctl boot" => "", "bootstatus" => "", "status_bar" => "")
    assert_equal "U2", StoreAutopilot::IosSimulator.new(shell).boot
    create = shell.captures.find { |c| c.include?("create") }
    assert_equal "rt.27", create.last
  end

  def test_ipad_creates_a_13_inch_ipad
    runtimes = JSON.generate(runtimes: [{ platform: "iOS", version: "27.0", identifier: "rt.27",
                                          supportedDeviceTypes: [{ identifier: "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M4-8GB" }] }])
    shell = FakeShell.new("list devices" => JSON.generate(devices: {}), "list runtimes" => runtimes,
                          "simctl create" => "U3\n", "simctl boot" => "", "bootstatus" => "", "status_bar" => "", "shutdown" => "")
    sim = StoreAutopilot::IosSimulator.new(shell, kind: :ipad)
    assert_equal "U3", sim.boot
    create = shell.captures.find { |c| c.include?("create") }
    assert_equal ["StoreAutopilot iPad 13in", "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M4-8GB"], create[3, 2]
    sim.shutdown
    assert_equal %w[xcrun simctl shutdown U3], shell.captures.last
  end

  def test_ipad_missing_from_runtime_is_explained
    runtimes = JSON.generate(runtimes: [{ platform: "iOS", version: "27.0", identifier: "rt.27",
                                          supportedDeviceTypes: [{ identifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max" }] }])
    shell = FakeShell.new("list devices" => JSON.generate(devices: {}), "list runtimes" => runtimes)
    err = assert_raises(StoreAutopilot::Error) { StoreAutopilot::IosSimulator.new(shell, kind: :ipad).boot }
    assert_includes err.message, "13\" iPad"
    assert_includes err.hint, "iPad Pro 13-inch"
  end

  # A simulator that was already running when we came is left running.
  def test_simulator_already_booted_is_not_shut_down
    devices = JSON.generate(devices: { "rt.27" => [{ name: StoreAutopilot::IosSimulator::NAME, udid: "U1", state: "Booted" }] })
    shell = FakeShell.new("list devices" => devices, "simctl boot" => "", "bootstatus" => "", "status_bar" => "")
    sim = StoreAutopilot::IosSimulator.new(shell)
    sim.boot
    sim.shutdown
    refute(shell.captures.any? { |c| c.include?("shutdown") })
  end

  def test_android_uses_running_emulator
    shell = FakeShell.new("adb devices" => "List of devices attached\nemulator-5554\tdevice\n", "getprop" => "1\n")
    assert_equal "emulator-5554", StoreAutopilot::AndroidEmulator.new(shell).boot
    assert_empty shell.runs
  end

  def test_android_unknown_avd_is_an_error
    shell = FakeShell.new("adb devices" => "List of devices attached\n", "-list-avds" => "Pixel_8\n")
    err = assert_raises(StoreAutopilot::Error) { StoreAutopilot::AndroidEmulator.new(shell, avd: "Nexus").boot }
    assert_includes err.message, "Pixel_8"
  end
end
