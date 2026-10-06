require "test_helper"

class RequirementsTest < Minitest::Test
  include Fixtures
  R = StoreAutopilot::Requirements

  def app(dir, gradle: "targetSdk = 36", deployment: "15.0")
    config = StoreAutopilot::Config.load(make_app(dir))
    FileUtils.mkdir_p(File.join(config.flutter_dir, "android/app"))
    File.write(File.join(config.flutter_dir, "android/app/build.gradle.kts"), "android {\n  defaultConfig {\n    #{gradle}\n  }\n}\n")
    FileUtils.mkdir_p(File.join(config.flutter_dir, "ios/Runner.xcodeproj"))
    File.write(File.join(config.flutter_dir, "ios/Runner.xcodeproj/project.pbxproj"), "IPHONEOS_DEPLOYMENT_TARGET = #{deployment};\n")
    config
  end

  def statuses(config, shell: FakeShell.new, today: Date.new(2026, 10, 7))
    R.new(config: config, shell: shell, today: today).findings(%i[ios android]).to_h { |f| [f.message[/\A[\w ]+?(?= \d| is|;)/], f.status] }
  end

  def test_all_current
    Dir.mktmpdir do |dir|
      assert_equal({ "Android target SDK" => :ok, "Xcode" => :ok, "iOS deployment target" => :ok }, statuses(app(dir)))
    end
  end

  def test_rules_in_force_fail_and_future_ones_warn
    Dir.mktmpdir do |dir|
      config = app(dir, gradle: "targetSdk = 35", deployment: "12.0")
      old_xcode = FakeShell.new("xcodebuild -version" => "Xcode 25.4\n")
      assert_equal({ "Android target SDK" => :fail, "Xcode" => :fail, "iOS deployment target" => :fail }, statuses(config, shell: old_xcode))
      before = statuses(config, shell: old_xcode, today: Date.new(2026, 1, 1))
      assert_equal :warn, before["Android target SDK"]
      assert_equal :warn, before["iOS deployment target"]
    end
  end

  def test_flutter_default_target_comes_from_the_installed_sdk
    Dir.mktmpdir do |dir|
      config = app(dir, gradle: "targetSdk = flutter.targetSdkVersion")
      kotlin = File.join(dir, "flutter/packages/flutter_tools/gradle/src/main/kotlin/FlutterExtension.kt")
      FileUtils.mkdir_p(File.dirname(kotlin))
      File.write(kotlin, "    val targetSdkVersion: Int = 35\n")
      shell = FakeShell.new("--version --machine" => JSON.generate(flutterRoot: File.join(dir, "flutter")))
      assert_equal 35, R.new(config: config, shell: shell).target_sdk
      assert_nil R.new(config: config, shell: FakeShell.new).target_sdk # unknown Flutter root
    end
  end

  def test_unknown_values_only_warn
    Dir.mktmpdir do |dir|
      config = StoreAutopilot::Config.load(make_app(dir))
      shell = FakeShell.new("xcodebuild -version" => "")
      assert(R.new(config: config, shell: shell).findings(%i[ios android]).all? { |f| f.status == :warn })
    end
  end

  def test_release_stops_before_building_for_a_rule_in_force
    Dir.mktmpdir do |dir|
      home = File.join(dir, "home")
      make_secrets(home)
      config = app(dir, gradle: "targetSdk = 34")
      shell = FakeShell.new
      err = assert_raises(StoreAutopilot::Error) do
        StoreAutopilot::Pipeline.new(config: config, shell: shell, platforms: [:android], home: home).release
      end
      assert_includes err.message, "Android target SDK is 34"
      assert_empty shell.runs
    end
  end
end
