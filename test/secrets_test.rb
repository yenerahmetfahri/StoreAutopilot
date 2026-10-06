require "test_helper"

class SecretsTest < Minitest::Test
  include Fixtures

  def test_complete_dir_has_no_problems
    Dir.mktmpdir do |home|
      make_secrets(home)
      assert_empty StoreAutopilot::Secrets.new("demo-app", home: home).problems([:ios, :android])
    end
  end

  def test_missing_and_loose_files_are_reported_without_contents
    Dir.mktmpdir do |home|
      dir = make_secrets(home)
      File.delete(File.join(dir, "play.json"))
      File.chmod(0o644, File.join(dir, "asc_key.p8"))
      msgs = StoreAutopilot::Secrets.new("demo-app", home: home).problems([:ios, :android]).map(&:first)
      assert(msgs.any? { |m| m.include?("play.json") && m.include?("missing") })
      assert(msgs.any? { |m| m.include?("asc_key.p8") && m.include?("readable by others") })
      refute(msgs.any? { |m| m.include?("BEGIN PRIVATE KEY") })
    end
  end

  def test_only_requested_platforms_are_checked
    Dir.mktmpdir do |home|
      dir = make_secrets(home)
      File.delete(File.join(dir, "play.json"))
      assert_empty StoreAutopilot::Secrets.new("demo-app", home: home).problems([:ios])
    end
  end

  def test_bad_json_is_reported
    Dir.mktmpdir do |home|
      dir = make_secrets(home)
      File.write(File.join(dir, "asc_key.json"), "{}")
      File.write(File.join(dir, "play.json"), "not json")
      msgs = StoreAutopilot::Secrets.new("demo-app", home: home).problems([:ios, :android]).map(&:first)
      assert(msgs.any? { |m| m.include?("key_id") })
      assert(msgs.any? { |m| m.include?("service account") })
    end
  end

  def test_tighten_fixes_permissions
    Dir.mktmpdir do |home|
      dir = make_secrets(home)
      File.chmod(0o755, dir)
      File.chmod(0o644, File.join(dir, "play.json"))
      fixed = StoreAutopilot::Secrets.new("demo-app", home: home).tighten!
      assert_equal 2, fixed.size
      assert_equal 0o700, File.stat(dir).mode & 0o777
      assert_equal 0o600, File.stat(File.join(dir, "play.json")).mode & 0o777
    end
  end

  def test_ensure_dir_creates_private_dir
    Dir.mktmpdir do |home|
      s = StoreAutopilot::Secrets.new("demo-app", home: home)
      s.ensure_dir!
      assert_equal 0o700, File.stat(s.dir).mode & 0o777
    end
  end

  def test_demo_password_only_when_store_md_names_a_demo_user
    Dir.mktmpdir do |home|
      secrets = StoreAutopilot::Secrets.new("demo-app", home: home)
      plain = StoreAutopilot::Listing.parse(Fixtures::VALID_MD)
      assert_equal [nil, nil], secrets.demo_password(plain)
      demo = StoreAutopilot::Listing.parse(Fixtures::VALID_MD.sub("---\n", "---\nreview_demo_user: rev@example.com\n"))
      assert_includes secrets.demo_password(demo).last, "review_demo_password.txt is missing"
      FileUtils.mkdir_p(secrets.dir)
      File.write(secrets.demo_password_path, "pw123\n")
      assert_equal ["pw123", nil], secrets.demo_password(demo)
    end
  end
end
