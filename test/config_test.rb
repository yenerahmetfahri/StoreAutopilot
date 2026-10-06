require "test_helper"

class ConfigTest < Minitest::Test
  include Fixtures

  def test_loads_valid_config
    Dir.mktmpdir do |dir|
      c = StoreAutopilot::Config.load(make_app(dir))
      assert_equal "demo-app", c.app_id
      assert_equal File.join(File.realpath(dir), "app"), File.realpath(c.flutter_dir)
      assert_equal({ "en" => { apple: "en-US", play: "en-US" } }, c.locales)
      assert_equal %w[01_home 02_play], c.screenshots
      assert_equal [:ios, :android], c.platforms
      assert_equal "internal", c.android[:track]
      assert_equal "completed", c.android[:release_status]
      assert_equal "1.2.3", c.version_name
      assert_equal File.join(dir, "store.md"), c.listing_path
    end
  end

  def test_reports_all_problems_at_once
    yml = "app_id: Bad Id\nflutter_project: nope\nscreenshots: [Home]\nbrand: { background: red, font: 'x\"y' }\n"
    Dir.mktmpdir do |dir|
      err = assert_raises(StoreAutopilot::Error) { StoreAutopilot::Config.load(make_app(dir, yml: yml)) }
      %w[app_id flutter_project locales screenshots brand.background brand.font ios].each do |word|
        assert_includes err.message, word
      end
    end
  end

  def test_wrong_shapes_are_reported_not_crashed_on
    Dir.mktmpdir do |dir|
      err = assert_raises(StoreAutopilot::Error) { StoreAutopilot::Config.load(make_app(dir, yml: "- just\n- a list\n")) }
      assert_includes err.message, "mapping"
      yml = Fixtures::VALID_YML.sub(/^ios:\n  bundle_id: com.example.demo\n/, "ios: com.example.demo\n").sub("brand:\n", "brand: blue\nx:\n")
      err = assert_raises(StoreAutopilot::Error) { StoreAutopilot::Config.load(make_app(dir, yml: yml)) }
      assert_includes err.message, "ios: expected settings"
      assert_includes err.message, "brand: expected settings"
    end
  end

  def pbxproj(dir, family)
    path = File.join(dir, "app", "ios", "Runner.xcodeproj", "project.pbxproj")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "buildSettings = {\n\t\t\t\tTARGETED_DEVICE_FAMILY = #{family};\n}")
  end

  def test_ipad_follows_the_xcode_project
    Dir.mktmpdir do |dir|
      path = make_app(dir)
      refute StoreAutopilot::Config.load(path).ipad? # no Xcode project
      pbxproj(dir, "1")
      refute StoreAutopilot::Config.load(path).ipad?
      pbxproj(dir, '"1,2"')
      assert StoreAutopilot::Config.load(path).ipad?
    end
  end

  def test_ipad_setting_overrides_the_xcode_project
    Dir.mktmpdir do |dir|
      pbxproj(dir, '"1,2"')
      off = Fixtures::VALID_YML.sub("bundle_id: com.example.demo", "bundle_id: com.example.demo\n  ipad: false")
      refute StoreAutopilot::Config.load(make_app(dir, yml: off)).ipad?
      bad = Fixtures::VALID_YML.sub("bundle_id: com.example.demo", "bundle_id: com.example.demo\n  ipad: maybe")
      err = assert_raises(StoreAutopilot::Error) { StoreAutopilot::Config.load(make_app(dir, yml: bad)) }
      assert_includes err.message, "ios.ipad"
    end
  end

  def test_rollout_and_phased_release
    Dir.mktmpdir do |dir|
      c = StoreAutopilot::Config.load(make_app(dir))
      assert_equal 100, c.android[:rollout]
      refute c.ios[:phased_release]
      yml = Fixtures::VALID_YML.sub("package: com.example.demo", "package: com.example.demo\n  rollout: 20")
                               .sub("bundle_id: com.example.demo", "bundle_id: com.example.demo\n  phased_release: true")
      c = StoreAutopilot::Config.load(make_app(dir, yml: yml))
      assert_equal 20, c.android[:rollout]
      assert c.ios[:phased_release]
      [0, 120, "half"].each do |bad|
        err = assert_raises(StoreAutopilot::Error) do
          StoreAutopilot::Config.load(make_app(dir, yml: Fixtures::VALID_YML.sub("package: com.example.demo", "package: com.example.demo\n  rollout: #{bad}")))
        end
        assert_includes err.message, "android.rollout"
      end
    end
  end

  def test_missing_file_has_hint
    err = assert_raises(StoreAutopilot::Error) { StoreAutopilot::Config.load("/nonexistent/storeautopilot.yml") }
    assert_includes err.hint, "storeautopilot init"
  end

  def test_template_path_prefers_app_copy
    Dir.mktmpdir do |dir|
      c = StoreAutopilot::Config.load(make_app(dir))
      assert_equal File.join(StoreAutopilot::TEMPLATES, "app", "storeautopilot", "frame.html"), c.template_path("frame.html")
      FileUtils.mkdir_p(File.join(dir, "storeautopilot"))
      File.write(File.join(dir, "storeautopilot", "frame.html"), "x")
      assert_equal File.join(dir, "storeautopilot", "frame.html"), c.template_path("frame.html")
    end
  end
end
