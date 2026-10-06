require "test_helper"

class BuilderTest < Minitest::Test
  include Fixtures

  def aab_path(config) = File.join(config.flutter_dir, "build/app/outputs/bundle/release/app-release.aab")

  def build_android(dir, keytool_output)
    config = StoreAutopilot::Config.load(make_app(dir))
    shell = FakeShell.new("-printcert" => keytool_output)
    shell.on_run { FileUtils.mkdir_p(File.dirname(aab_path(config))); File.write(aab_path(config), "aab") }
    [StoreAutopilot::Builder.new(config: config, shell: shell).android(build_number: 9), shell]
  end

  def test_android_build_passes_version_and_number
    Dir.mktmpdir do |dir|
      aab, shell = build_android(dir, "Owner: CN=Real Dev, O=Example\n")
      assert aab.end_with?("app-release.aab")
      assert_equal %w[flutter build appbundle --release --build-name=1.2.3 --build-number=9], shell.runs.first
    end
  end

  def ios_app(dir, uses_encryption:, plist: "<plist><dict><key>CFBundleName</key><string>x</string></dict></plist>")
    yml = Fixtures::VALID_YML.sub("bundle_id: com.example.demo", "bundle_id: com.example.demo\n  uses_encryption: #{uses_encryption}")
    config = StoreAutopilot::Config.load(make_app(dir, yml: yml))
    FileUtils.mkdir_p(File.dirname(config.info_plist))
    File.write(config.info_plist, plist)
    config
  end

  # The real plutil edits the real file.
  def test_no_encryption_is_written_into_info_plist_once
    Dir.mktmpdir do |dir|
      config = ios_app(dir, uses_encryption: false)
      plutil = Class.new(FakeShell) { def capture(*cmd, **) = StoreAutopilot::Shell.new.capture(*cmd) }.new
      builder = StoreAutopilot::Builder.new(config: config, shell: plutil)
      builder.ios(build_number: 3)
      assert config.encryption_declared?
      assert_equal "false\n", StoreAutopilot::Shell.new.capture("plutil", "-extract", "ITSAppUsesNonExemptEncryption", "raw", config.info_plist)
      before = File.read(config.info_plist)
      builder.ios(build_number: 4)
      assert_equal before, File.read(config.info_plist)
    end
  end if RUBY_PLATFORM.include?("darwin")

  def test_info_plist_untouched_without_a_declaration
    Dir.mktmpdir do |dir|
      config = ios_app(dir, uses_encryption: "true")
      shell = FakeShell.new
      StoreAutopilot::Builder.new(config: config, shell: shell).ios(build_number: 3)
      refute config.encryption_declared?
      assert_empty shell.captures
    end
  end

  def test_debug_signed_aab_is_rejected
    Dir.mktmpdir do |dir|
      err = assert_raises(StoreAutopilot::Error) { build_android(dir, "Owner: CN=Android Debug, O=Android\n") }
      assert_includes err.message, "DEBUG"
    end
  end

  def test_unsigned_aab_is_rejected
    Dir.mktmpdir do |dir|
      err = assert_raises(StoreAutopilot::Error) { build_android(dir, "Not a signed jar file\n") }
      assert_includes err.message, "not signed"
    end
  end

  def test_ios_config_only_build
    Dir.mktmpdir do |dir|
      config = StoreAutopilot::Config.load(make_app(dir))
      shell = FakeShell.new
      ws = StoreAutopilot::Builder.new(config: config, shell: shell).ios(build_number: 9)
      assert_equal %w[flutter build ios --release --config-only --build-name=1.2.3 --build-number=9], shell.runs.first
      assert_equal File.join(config.flutter_dir, "ios", "Runner.xcworkspace"), ws
    end
  end
end
