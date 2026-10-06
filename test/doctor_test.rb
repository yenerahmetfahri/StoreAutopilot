require "test_helper"

class DoctorTest < Minitest::Test
  include Fixtures

  def repo_shell(private: true, tracked: "", untracked: "", heads: "abc\trefs/heads/release\n")
    FakeShell.new("repo view" => JSON.generate(isPrivate: private),
                  "ls-files --others" => untracked, "ls-files" => tracked, "ls-remote" => heads)
  end

  def checks(dir, shell)
    config = StoreAutopilot::Config.load(make_app(dir))
    FileUtils.mkdir_p(File.join(dir, ".github/workflows"))
    File.write(File.join(dir, ".github/workflows/store.yml"), "on:\n  push:\n    branches: [release]\n")
    StoreAutopilot::Doctor.new(config_path: File.join(dir, "storeautopilot.yml"), shell: shell).repo_checks(config)
  end

  def test_private_repo_with_clean_git_passes
    Dir.mktmpdir { |dir| assert(checks(dir, repo_shell).all? { |c| c.status == :ok }) }
  end

  def test_public_repo_fails
    Dir.mktmpdir do |dir|
      c = checks(dir, repo_shell(private: false)).find { |x| x.status == :fail }
      assert_includes c.message, "public"
    end
  end

  def test_tracked_secret_fails_and_untracked_warns
    Dir.mktmpdir do |dir|
      result = checks(dir, repo_shell(tracked: "lib/main.dart\nandroid/key.properties\n", untracked: "AuthKey_X.p8\n"))
      assert(result.any? { |c| c.status == :fail && c.message.include?("android/key.properties") })
      assert(result.any? { |c| c.status == :warn && c.message.include?("AuthKey_X.p8") })
    end
  end

  def test_pull_request_trigger_fails
    Dir.mktmpdir do |dir|
      config = StoreAutopilot::Config.load(make_app(dir))
      FileUtils.mkdir_p(File.join(dir, ".github/workflows"))
      File.write(File.join(dir, ".github/workflows/store.yml"), "on:\n  pull_request:\n")
      result = StoreAutopilot::Doctor.new(config_path: File.join(dir, "storeautopilot.yml"), shell: repo_shell).repo_checks(config)
      assert(result.any? { |c| c.status == :fail && c.message.include?("pull_request") })
    end
  end

  def test_missing_release_branch_warns
    Dir.mktmpdir do |dir|
      assert(checks(dir, repo_shell(heads: "")).any? { |c| c.status == :warn && c.message.include?("release") })
    end
  end
end

class DoctorOnlineTest < Minitest::Test
  include Fixtures

  # Fake fastlane whose status lanes report the given results.
  def store_shell(ios:, android:)
    shell = FakeShell.new
    shell.define_singleton_method(:capture) do |*cmd, env: {}, **|
      @captures << cmd
      out = JSON.parse(File.read(env["STOREAUTOPILOT_JOB"]))["output"]
      File.write(out, JSON.generate(cmd[1] == "ios" ? ios : android))
      "fastlane noise"
    end
    shell
  end

  def online_checks(shell)
    Dir.mktmpdir do |dir|
      home = File.join(dir, "home")
      make_secrets(home)
      config = StoreAutopilot::Config.load(make_app(dir))
      StoreAutopilot::Doctor.new(config_path: nil, shell: shell, home: home, online: true).online_checks(config)
    end
  end

  def test_reports_both_stores
    checks = online_checks(store_shell(ios: { app: true, live_version: "1.2.3" }, android: { tracks: { "internal" => [4] } }))
    assert_equal [:fail, :ok], checks.map(&:status)
    assert_includes checks.first.message, "1.2.3"
    assert_includes checks.last.message, "version code 4"
  end

  def test_a_crashing_lane_is_a_failed_check
    shell = FakeShell.new("fastlane" => "boom")
    checks = online_checks(shell)
    assert_equal [:fail, :fail], checks.map(&:status)
    assert_includes checks.first.hint, "log"
  end

  def test_skipped_without_keys
    Dir.mktmpdir do |dir|
      config = StoreAutopilot::Config.load(make_app(dir))
      checks = StoreAutopilot::Doctor.new(config_path: nil, shell: FakeShell.new, home: dir, online: true).online_checks(config)
      assert_equal [:warn], checks.map(&:status)
    end
  end
end

class DoctorEncryptionTest < Minitest::Test
  include Fixtures

  def check(dir, setting: nil, plist: nil)
    yml = setting.nil? ? Fixtures::VALID_YML : Fixtures::VALID_YML.sub("bundle_id: com.example.demo", "bundle_id: com.example.demo\n  uses_encryption: #{setting}")
    config = StoreAutopilot::Config.load(make_app(dir, yml: yml))
    if plist
      FileUtils.mkdir_p(File.dirname(config.info_plist))
      File.write(config.info_plist, plist)
    end
    StoreAutopilot::Doctor.new(config_path: nil, shell: FakeShell.new).send(:encryption_check, config)
  end

  def test_grades
    Dir.mktmpdir do |dir|
      assert_equal :warn, check(dir).status
      assert_includes check(dir).hint, "uses_encryption: false"
      assert_equal :ok, check(dir, setting: false).status
      assert_equal :warn, check(dir, setting: true).status
      assert_equal :ok, check(dir, plist: "<key>ITSAppUsesNonExemptEncryption</key><false/>").status
    end
  end
end
