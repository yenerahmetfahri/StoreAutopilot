require "date"
require "json"

module StoreAutopilot
  # Store rules that tighten over time (target SDK, Xcode version, minimum OS). A rule in force fails before anything
  # is built, instead of the store rejecting the upload; one that starts later is a warning with its date.
  class Requirements
    Rule = Struct.new(:platform, :kind, :min, :from, :what, keyword_init: true)
    RULES = [
      Rule.new(platform: :android, kind: :target_sdk, min: 36, from: Date.new(2026, 8, 31),
               what: "Google Play requires new apps and updates to target Android 16 (API 36)"),
      Rule.new(platform: :ios, kind: :xcode, min: 26, from: Date.new(2026, 4, 28),
               what: "the App Store requires builds made with Xcode 26 (iOS 26 SDK) or later"),
      Rule.new(platform: :ios, kind: :deployment_target, min: 13, from: Date.new(2026, 9, 9),
               what: "the App Store requires a minimum deployment target of iOS 13 or later")
    ].freeze
    HINTS = {
      target_sdk: "Upgrade Flutter (its default target follows Android), or raise targetSdk in android/app/build.gradle(.kts).",
      xcode: "Install the current Xcode from the App Store.",
      deployment_target: "Raise IPHONEOS_DEPLOYMENT_TARGET in ios/Runner.xcodeproj (and the Podfile's platform line)."
    }.freeze

    def initialize(config:, shell:, today: Date.today, rules: RULES)
      @config = config
      @shell = shell
      @today = today
      @rules = rules
    end

    # StoreStatus::Finding list for the given platforms.
    def findings(platforms)
      @rules.select { |r| platforms.include?(r.platform) }.map { |rule| check(rule) }
    end

    def target_sdk
      gradle = Dir[File.join(@config.flutter_dir, "android", "app", "build.gradle{,.kts}")].first
      text = gradle ? File.read(gradle) : ""
      literal = text[/targetSdk(?:Version)?\s*=?\s*(\d+)/, 1]
      return literal.to_i if literal
      flutter_default_target_sdk if text.include?("flutter.targetSdkVersion")
    end

    def xcode = version_capture("xcodebuild", "-version")&.[](/Xcode (\d+)/, 1)&.to_i

    def deployment_target
      pbx = File.join(@config.flutter_dir, "ios", "Runner.xcodeproj", "project.pbxproj")
      return nil unless File.file?(pbx)
      File.read(pbx).scan(/IPHONEOS_DEPLOYMENT_TARGET = ([\d.]+);/).flatten.map(&:to_f).min
    end

    private

    def check(rule)
      value = public_send(rule.kind)
      label = { target_sdk: "Android target SDK", xcode: "Xcode", deployment_target: "iOS deployment target" }.fetch(rule.kind)
      if value.nil?
        return StoreStatus::Finding.new(:warn, "could not tell the #{label}; #{rule.what} from #{rule.from}", HINTS.fetch(rule.kind))
      end
      shown = value.is_a?(Float) && value == value.floor ? value.to_i : value
      return StoreStatus::Finding.new(:ok, "#{label} #{shown}") if value >= rule.min
      status = @today >= rule.from ? :fail : :warn
      when_text = @today >= rule.from ? "since #{rule.from}" : "from #{rule.from}"
      StoreStatus::Finding.new(status, "#{label} is #{shown}; #{rule.what} #{when_text}", HINTS.fetch(rule.kind))
    end

    # Flutter's default for flutter.targetSdkVersion, read from the installed Flutter SDK.
    def flutter_default_target_sdk
      root = JSON.parse(version_capture("flutter", "--version", "--machine") || "{}")["flutterRoot"]
      file = root && File.join(root, "packages", "flutter_tools", "gradle", "src", "main", "kotlin", "FlutterExtension.kt")
      return nil unless file && File.file?(file)
      File.read(file)[/val targetSdkVersion: Int = (\d+)/, 1]&.to_i
    rescue JSON::ParserError
      nil
    end

    def version_capture(*cmd)
      @shell.capture(*cmd, allow_failure: true, timeout: 60)
    rescue Error
      nil
    end
  end
end
