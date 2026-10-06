module StoreAutopilot
  class Builder
    def initialize(config:, shell:)
      @config = config
      @shell = shell
    end

    # Generates Xcode config for this version/number; the archive itself is built by fastlane gym.
    def ios(build_number:)
      @shell.run("flutter", "build", "ios", "--release", "--config-only", *version_args(build_number), chdir: @config.flutter_dir)
      declare_no_encryption if @config.ios[:uses_encryption] == false
      File.join(@config.flutter_dir, "ios", "Runner.xcworkspace")
    end

    # Without ITSAppUsesNonExemptEncryption every TestFlight build waits for an export compliance answer in App Store
    # Connect. ios.uses_encryption: false is the developer's declaration; it is written into Info.plist once.
    def declare_no_encryption
      return if !File.file?(@config.info_plist) || @config.encryption_declared?
      @shell.capture("plutil", "-insert", "ITSAppUsesNonExemptEncryption", "-bool", "NO", @config.info_plist)
      UI.ok("ios/Runner/Info.plist: declared no non-exempt encryption (commit this change)")
    end

    def android(build_number:)
      @shell.run("flutter", "build", "appbundle", "--release", *version_args(build_number), chdir: @config.flutter_dir)
      aab = File.join(@config.flutter_dir, "build/app/outputs/bundle/release/app-release.aab")
      raise Error.new("Build finished but #{aab} is missing.") unless File.file?(aab)
      verify_signed!(aab)
      aab
    end

    # Play rejects unsigned or debug-signed bundles; catch it before uploading.
    def verify_signed!(aab)
      out = @shell.capture(Env.keytool, "-printcert", "-jarfile", aab, allow_failure: true)
      unless out.include?("Owner:")
        raise Error.new("app-release.aab is not signed.", hint: "Configure release signing in android/app/build.gradle(.kts).")
      end
      return unless out.include?("CN=Android Debug")
      raise Error.new("app-release.aab is signed with the DEBUG key; Google Play will reject it.",
                      hint: "Your Gradle signing config could not find the upload keystore (check its key.properties path).")
    end

    private

    def version_args(number) = ["--build-name=#{@config.version_name}", "--build-number=#{number}"]
  end
end
