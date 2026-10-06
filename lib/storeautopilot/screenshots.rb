require "fileutils"

module StoreAutopilot
  # Runs the app's screenshot integration test on a real simulator/emulator, once per locale.
  # Targets: :ios (iPhone), :ipad and :android.
  class Screenshots
    DEVICE = { ios: "phone", ipad: "tablet", android: "phone" }.freeze

    TEST = "integration_test/store_screenshots_test.dart"
    DRIVER = "test_driver/store_screenshots_driver.dart"

    def initialize(config:, shell:, devices: nil)
      @config = config
      @shell = shell
      @devices = devices || {
        ios: IosSimulator.new(shell),
        ipad: IosSimulator.new(shell, kind: :ipad),
        android: AndroidEmulator.new(shell, avd: config.android && config.android[:emulator])
      }
    end

    def missing_files = [TEST, DRIVER].reject { |rel| File.file?(File.join(@config.flutter_dir, rel)) }

    def capture(platform, raw_dir)
      if missing_files.any?
        raise Error.new("Missing #{missing_files.join(', ')} in #{@config.flutter_dir}", hint: "Run `storeautopilot init` and fill in the test.")
      end
      device = @devices.fetch(platform).boot
      @config.locales.each_key do |locale|
        dir = File.join(raw_dir, platform.to_s, locale)
        FileUtils.rm_rf(dir)
        FileUtils.mkdir_p(dir)
        UI.info("#{platform} · #{locale}")
        @shell.run("flutter", "drive", "--driver=#{DRIVER}", "--target=#{TEST}", "-d", device,
                   "--dart-define=STORE_LOCALE=#{locale}", "--dart-define=STORE_PLATFORM=#{platform == :ipad ? :ios : platform}",
                   "--dart-define=STORE_DEVICE=#{DEVICE.fetch(platform)}",
                   chdir: @config.flutter_dir, env: { "STORE_SHOTS_DIR" => dir })
        missing = @config.screenshots.reject { |s| File.file?(File.join(dir, "#{s}.png")) }
        next if missing.empty?
        raise Error.new("#{platform}/#{locale}: no screenshot for #{missing.join(', ')}",
                        hint: "Call takeStoreScreenshot(tester, '<id>') for every id in storeautopilot.yml.")
      end
    ensure
      device = @devices[platform]
      device.shutdown if device.respond_to?(:shutdown)
    end
  end
end
