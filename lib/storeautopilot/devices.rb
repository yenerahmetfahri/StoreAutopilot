require "json"

module StoreAutopilot
  # A dedicated simulator in the size the App Store asks for, created on first use so the user's own simulators stay
  # untouched: a 6.9" iPhone (1320x2868) or a 13" iPad (2064x2752).
  class IosSimulator
    KINDS = {
      iphone: { name: "StoreAutopilot iPhone 6.9in", label: "6.9\" iPhone", hint: "iPhone 16/17 Pro Max",
                types: %w[iPhone-17-Pro-Max iPhone-16-Pro-Max] },
      ipad: { name: "StoreAutopilot iPad 13in", label: "13\" iPad", hint: "iPad Pro 13-inch (M4 or M5)",
              types: %w[iPad-Pro-13-inch-M5-12GB iPad-Pro-13-inch-M4-8GB iPad-Pro-13-inch-M5-16GB iPad-Pro-13-inch-M4-16GB] }
    }.freeze
    NAME = KINDS[:iphone][:name]

    def initialize(shell, kind: :iphone)
      @shell = shell
      @kind = KINDS.fetch(kind)
    end

    def boot
      device = find
      udid = device ? device["udid"] : create
      @started = device.nil? || device["state"] != "Booted"
      @shell.capture("xcrun", "simctl", "boot", udid, allow_failure: true) # already booted is fine
      @shell.capture("xcrun", "simctl", "bootstatus", udid, "-b", timeout: 300)
      @shell.capture("xcrun", "simctl", "status_bar", udid, "override", "--time", "9:41", "--batteryState", "charged",
                     "--batteryLevel", "100", "--cellularBars", "4", "--wifiBars", "3")
      @udid = udid
    end

    # Shuts the simulator down again if boot started it.
    def shutdown
      @shell.capture("xcrun", "simctl", "shutdown", @udid, allow_failure: true) if @started && @udid
    end

    private

    def find
      devices = JSON.parse(@shell.capture("xcrun", "simctl", "list", "devices", "available", "-j"))["devices"]
      devices.values.flatten.find { |d| d["name"] == @kind[:name] }
    end

    def create
      runtimes = JSON.parse(@shell.capture("xcrun", "simctl", "list", "runtimes", "available", "-j"))["runtimes"]
      runtime = runtimes.select { |r| r["platform"] == "iOS" }.max_by { |r| Gem::Version.new(r["version"]) }
      raise Error.new("No iOS simulator runtime installed.", hint: "Xcode → Settings → Components: install an iOS runtime.") unless runtime
      types = @kind[:types].map { |t| "com.apple.CoreSimulator.SimDeviceType.#{t}" }
      supported = Array(runtime["supportedDeviceTypes"]).map { |t| t["identifier"] }
      type = supported.empty? ? types.first : types.find { |t| supported.include?(t) }
      unless type
        raise Error.new("iOS #{runtime['version']} has no #{@kind[:label]} simulator.",
                        hint: "Install an iOS runtime that supports the #{@kind[:hint]}.")
      end
      @shell.capture("xcrun", "simctl", "create", @kind[:name], type, runtime["identifier"]).strip
    end
  end

  # Uses a running emulator, or boots an AVD headless and waits for it.
  class AndroidEmulator
    def initialize(shell, avd: nil, timeout: 300)
      @shell = shell
      @avd = avd
      @timeout = timeout
    end

    def boot
      serial = running
      return serial if serial && booted?(serial)
      unless serial
        names = avds
        name = @avd || names.first
        raise Error.new("No Android emulator (AVD) found.", hint: "Android Studio → Device Manager: create one (e.g. Pixel 8).") unless name
        raise Error.new("AVD `#{name}` not found. Available: #{names.join(', ')}", hint: "Fix android.emulator in storeautopilot.yml.") unless names.include?(name)
        @shell.spawn_bg(Env.sdk_tool("emulator/emulator"), "-avd", name, "-no-window", "-no-audio", "-no-boot-anim", "-no-snapshot-save")
        @started = true
      end
      wait
    end

    def shutdown
      serial = running
      @shell.capture(adb, "-s", serial, "emu", "kill", allow_failure: true) if @started && serial
    end

    private

    def adb = Env.sdk_tool("platform-tools/adb")
    def avds = @shell.capture(Env.sdk_tool("emulator/emulator"), "-list-avds").lines.map(&:strip).reject(&:empty?)

    def running
      @shell.capture(adb, "devices").lines.map { |l| l.strip.split("\t") }
            .find { |serial, status| serial.to_s.start_with?("emulator-") && status == "device" }&.first
    end

    def booted?(serial) = @shell.capture(adb, "-s", serial, "shell", "getprop", "sys.boot_completed", allow_failure: true).strip == "1"

    def wait
      deadline = Time.now + @timeout
      loop do
        serial = running
        return serial if serial && booted?(serial)
        raise Error.new("Android emulator did not boot within #{@timeout}s.", hint: "Start it once from Android Studio to check it works.") if Time.now > deadline
        sleep 3
      end
    end
  end
end
