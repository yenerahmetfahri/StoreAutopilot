require "test_helper"

class PipelineTest < Minitest::Test
  include Fixtures

  IOS_STATUS = { app: true, live_version: nil, build_number: 7 }.freeze
  READY = { app: true, version: "1.2.3", build: { number: "7", state: "VALID" }, screenshots: { "en-US" => ["APP_IPHONE_67"] },
            review_contact: true, age_rating_unanswered: [], content_rights: "DOES_NOT_USE_THIRD_PARTY_CONTENT",
            privacy_urls: { "en-US" => "https://example.com/privacy" } }.freeze

  # A quiet lane (fastlane run through capture) that writes result as its output.
  def self.lane_result(result)
    lambda do |_cmd, env|
      File.write(JSON.parse(File.read(env["STOREAUTOPILOT_JOB"]))["output"], JSON.generate(result))
      ""
    end
  end

  # Fake fastlane: the status lanes report ios_status / android_status; every lane is recorded.
  def fake_shell(ios_status: IOS_STATUS, android_status: { tracks: { "internal" => [5] }, errors: {} }, readiness: READY)
    shell = FakeShell.new("fastlane ios readiness" => PipelineTest.lane_result(readiness))
    shell.on_run do |cmd, env|
      next unless cmd.first == "fastlane" && cmd[2] == "status"
      job = JSON.parse(File.read(env["STOREAUTOPILOT_JOB"]))
      File.write(job["output"], JSON.generate(cmd[1] == "ios" ? ios_status : android_status))
    end
    shell
  end

  def release_ios(dir, shell)
    home = File.join(dir, "home")
    make_secrets(home)
    config = StoreAutopilot::Config.load(make_app(dir))
    StoreAutopilot::Pipeline.new(config: config, shell: shell, platforms: [:ios], skip_shots: true, home: home).release
  end

  def lanes(shell) = shell.runs.select { |c| c.first == "fastlane" }.map { |c| c[1..2].join(" ") }

  def test_release_ios_then_skips_unchanged_metadata
    Dir.mktmpdir do |dir|
      home = File.join(dir, "home")
      make_secrets(home)
      config = StoreAutopilot::Config.load(make_app(dir))
      shell = fake_shell
      pipeline = StoreAutopilot::Pipeline.new(config: config, shell: shell, platforms: [:ios], skip_shots: true, home: home)
      pipeline.release
      assert_equal ["ios status", "ios upload", "ios metadata"], lanes(shell)
      assert_includes shell.runs.find { |c| c.first == "flutter" }, "--build-number=8"

      shell2 = fake_shell
      StoreAutopilot::Pipeline.new(config: config, shell: shell2, platforms: [:ios], skip_shots: true, home: home).release
      assert_equal ["ios status", "ios upload"], lanes(shell2)
      assert_includes shell2.runs.find { |c| c.first == "flutter" }, "--build-number=9"
    end
  end

  # pubspec says 1.2.3; the store already has it live, so nothing is built.
  def test_testflight_notes_only_when_enabled
    Dir.mktmpdir do |dir|
      shell = fake_shell
      release_ios(dir, shell)
      assert_equal({}, shell.jobs["ios upload"]["testflight_notes"])
    end
    Dir.mktmpdir do |dir|
      home = File.join(dir, "home")
      make_secrets(home)
      yml = Fixtures::VALID_YML.sub("bundle_id: com.example.demo", "bundle_id: com.example.demo\n  testflight_notes: true")
      config = StoreAutopilot::Config.load(make_app(dir, yml: yml))
      shell = fake_shell
      StoreAutopilot::Pipeline.new(config: config, shell: shell, platforms: [:ios], skip_shots: true, home: home).release
      assert_equal({ "en-US" => "Bug fixes." }, shell.jobs["ios upload"]["testflight_notes"])
    end
  end

  def test_release_stops_when_the_version_is_already_live
    Dir.mktmpdir do |dir|
      shell = fake_shell(ios_status: IOS_STATUS.merge(live_version: "1.2.3"))
      err = assert_raises(StoreAutopilot::Error) { release_ios(dir, shell) }
      assert_includes err.message, "already live"
      assert_includes err.hint, "1.2.4"
      assert_equal ["ios status"], lanes(shell)
      refute(shell.runs.any? { |c| c.first == "flutter" })
    end
  end

  def test_release_stops_when_the_app_record_is_missing
    Dir.mktmpdir do |dir|
      err = assert_raises(StoreAutopilot::Error) { release_ios(dir, fake_shell(ios_status: { app: false })) }
      assert_includes err.message, "No app with bundle ID com.example.demo"
    end
  end

  def test_release_uses_the_highest_number_of_both_stores
    Dir.mktmpdir do |dir|
      home = File.join(dir, "home")
      make_secrets(home)
      config = StoreAutopilot::Config.load(make_app(dir))
      shell = fake_shell(android_status: { tracks: { "internal" => [5], "alpha" => [12] }, errors: { "beta" => "x" } })
      pipeline = StoreAutopilot::Pipeline.new(config: config, shell: shell, platforms: [:ios, :android], skip_shots: true, home: home)
      %i[upload_ios upload_android listing_ios listing_android].each { |m| pipeline.define_singleton_method(m) { |*| nil } }
      pipeline.release
      assert_equal 13, JSON.parse(File.read(File.join(home, ".storeautopilot", "demo-app", "state.json")))["build_number"]
    end
  end

  def test_shots_add_ipad_when_the_app_runs_on_ipad
    Dir.mktmpdir do |dir|
      home = File.join(dir, "home")
      make_secrets(home)
      path = make_app(dir)
      FileUtils.mkdir_p(File.join(dir, "app", "ios", "Runner.xcodeproj"))
      File.write(File.join(dir, "app", "ios", "Runner.xcodeproj", "project.pbxproj"), 'TARGETED_DEVICE_FAMILY = "1,2";')
      config = StoreAutopilot::Config.load(path)
      targets = []
      screenshots = Object.new
      screenshots.define_singleton_method(:capture) do |target, raw|
        targets << target
        config.screenshots.each do |s|
          FileUtils.mkdir_p(File.join(raw, target.to_s, "en"))
          File.write(File.join(raw, target.to_s, "en", "#{s}.png"), "raw")
        end
      end
      compose = ImagesTest::FakeCompose.new
      pipeline = StoreAutopilot::Pipeline.new(config: config, shell: FakeShell.new("ls-files" => ""), platforms: [:ios], home: home,
                                              screenshots: screenshots, compose: compose)
      page = pipeline.shots
      store = File.dirname(page)
      assert_equal [:ios, :ipad], targets
      assert File.file?(File.join(store, "ios", "screenshots", "en-US", "ipad_02_play.png"))
      assert_includes File.read(page), %(src="ios/screenshots/en-US/ipad_02_play.png")
    end
  end

  # Records each capture and writes the raw files it would have produced.
  def fake_screenshots(config, targets)
    Object.new.tap do |shots|
      shots.define_singleton_method(:capture) do |target, raw|
        targets << target
        config.screenshots.each do |s|
          FileUtils.mkdir_p(File.join(raw, target.to_s, "en"))
          File.write(File.join(raw, target.to_s, "en", "#{s}.png"), "raw")
        end
      end
    end
  end

  def test_unchanged_app_reuses_its_screenshots
    Dir.mktmpdir do |dir|
      home = File.join(dir, "home")
      make_secrets(home)
      config = StoreAutopilot::Config.load(make_app(dir))
      main = File.join(config.flutter_dir, "lib", "main.dart")
      FileUtils.mkdir_p(File.dirname(main))
      File.write(main, "v1")
      shell = FakeShell.new("ls-files" => "lib/main.dart\0pubspec.yaml\0")
      targets = []
      run = lambda do |**opts|
        StoreAutopilot::Pipeline.new(config: config, shell: shell, platforms: [:ios], home: home,
                                     screenshots: fake_screenshots(config, targets), compose: ImagesTest::FakeCompose.new, **opts).shots
      end
      run.call
      File.write(File.join(config.flutter_dir, "pubspec.yaml"), "name: demo_app\nversion: 9.9.9+1\n") # version only
      run.call
      assert_equal [:ios], targets
      run.call(fresh_shots: true)
      assert_equal [:ios, :ios], targets
      File.write(main, "v2")
      run.call
      assert_equal [:ios, :ios, :ios], targets
    end
  end

  # Both platforms with fakes for the builds; Android fails the first time.
  def release_both(dir, shell, android_fails: false)
    home = File.join(dir, "home")
    make_secrets(home) unless File.directory?(home)
    config = StoreAutopilot::Config.load(make_app(dir))
    pipeline = StoreAutopilot::Pipeline.new(config: config, shell: shell, skip_shots: true, home: home)
    pipeline.define_singleton_method(:upload_android) do |_listing, _number|
      raise StoreAutopilot::Error, "Play upload failed" if android_fails
      @fastlane.lane(:android, :upload, {})
    end
    pipeline.release
  end

  def git_shell(sha: "a" * 40, dirty: "")
    fake_shell.tap { |s| s.instance_variable_get(:@outputs).merge!("rev-parse" => "#{sha}\n", "status --porcelain" => dirty) }
  end

  def test_rerun_of_the_same_commit_skips_builds_already_uploaded
    Dir.mktmpdir do |dir|
      first = git_shell
      assert_raises(StoreAutopilot::Error) { release_both(dir, first, android_fails: true) }
      assert_includes lanes(first), "ios upload"

      second = git_shell
      release_both(dir, second)
      refute_includes lanes(second), "ios upload"
      assert_includes lanes(second), "android upload"
      refute(second.runs.any? { |c| c.first == "flutter" }) # no iOS build either
    end
  end

  def test_new_commit_or_local_changes_build_everything_again
    Dir.mktmpdir do |dir|
      assert_raises(StoreAutopilot::Error) { release_both(dir, git_shell, android_fails: true) }
      other = git_shell(sha: "b" * 40)
      release_both(dir, other)
      assert_includes lanes(other), "ios upload"
      dirty = git_shell(sha: "b" * 40, dirty: " M lib/main.dart\n")
      release_both(dir, dirty)
      assert_includes lanes(dirty), "ios upload"
    end
  end

  def test_status_shows_both_stores
    Dir.mktmpdir do |dir|
      home = File.join(dir, "home")
      make_secrets(home)
      config = StoreAutopilot::Config.load(make_app(dir))
      shell = FakeShell.new
      shell.define_singleton_method(:capture) do |*cmd, env: {}, **|
        out = JSON.parse(File.read(env["STOREAUTOPILOT_JOB"]))["output"]
        status = cmd[1] == "ios" ? { app: true, live_version: "1.2.2", in_review_version: "1.2.3", build_number: 41 }
                                 : { tracks: { "internal" => [41, 40], "production" => [] }, errors: {} }
        File.write(out, JSON.generate(status))
        ""
      end
      StoreAutopilot::UI.out = (out = StringIO.new)
      StoreAutopilot::Pipeline.new(config: config, shell: shell, home: home).status
      text = out.string
      assert_match(/live\s+1\.2\.2/, text)
      assert_match(/in review\s+1\.2\.3/, text)
      assert_match(/approved, not released\s+—/, text)
      assert_match(/internal\s+version code 41/, text)
      assert_match(/production\s+—/, text)
      assert_includes text, "! Version 1.2.3 is in App Review"
    end
  end

  def test_missing_demo_password_stops_before_any_command
    Dir.mktmpdir do |dir|
      home = File.join(dir, "home")
      make_secrets(home)
      md = Fixtures::VALID_MD.sub("---\n", "---\nreview_demo_user: rev@example.com\n")
      config = StoreAutopilot::Config.load(make_app(dir, store_md: md))
      shell = fake_shell
      err = assert_raises(StoreAutopilot::Error) { StoreAutopilot::Pipeline.new(config: config, shell: shell, home: home).release }
      assert_includes err.message, "review_demo_password.txt is missing"
      assert_empty shell.runs
    end
  end

  def test_data_safety_csv_is_uploaded_when_it_changes
    Dir.mktmpdir do |dir|
      home = File.join(dir, "home")
      make_secrets(home)
      config = StoreAutopilot::Config.load(make_app(dir))
      csv = File.join(dir, "storeautopilot", "data_safety.csv")
      FileUtils.mkdir_p(File.dirname(csv))
      File.write(csv, "Question ID,Response ID\n")
      run = lambda do
        shell = fake_shell
        pipeline = StoreAutopilot::Pipeline.new(config: config, shell: shell, platforms: [:android], skip_shots: true, home: home)
        pipeline.define_singleton_method(:upload_android) { |*| nil }
        pipeline.release
        shell
      end
      first = run.call
      assert_includes lanes(first), "android data_safety"
      assert_equal csv, first.jobs["android data_safety"]["csv"]
      refute_includes lanes(run.call), "android data_safety"
      File.write(csv, "Question ID,Response ID\nPSL_X,PSL_Y\n")
      assert_includes lanes(run.call), "android data_safety"
    end
  end

  def test_dry_run_touches_nothing
    Dir.mktmpdir do |dir|
      home = File.join(dir, "home")
      make_secrets(home)
      config = StoreAutopilot::Config.load(make_app(dir))
      shell = fake_shell
      StoreAutopilot::UI.out = (out = StringIO.new)
      StoreAutopilot::Pipeline.new(config: config, shell: shell, dry_run: true, home: home).release
      assert_empty shell.runs
      assert_includes out.string, "would"
    end
  end

  def test_missing_secrets_stop_before_any_command
    Dir.mktmpdir do |dir|
      config = StoreAutopilot::Config.load(make_app(dir))
      shell = fake_shell
      err = assert_raises(StoreAutopilot::Error) do
        StoreAutopilot::Pipeline.new(config: config, shell: shell, home: File.join(dir, "empty")).release
      end
      assert_includes err.message, "Secrets"
      assert_empty shell.runs
    end
  end

  def test_invalid_listing_stops_before_any_command
    Dir.mktmpdir do |dir|
      home = File.join(dir, "home")
      make_secrets(home)
      config = StoreAutopilot::Config.load(make_app(dir, store_md: "# en\n## name\nX\n"))
      shell = fake_shell
      assert_raises(StoreAutopilot::Error) { StoreAutopilot::Pipeline.new(config: config, shell: shell, home: home).release }
      assert_empty shell.runs
    end
  end

  def test_submit_passes_rollout_and_phased_release
    Dir.mktmpdir do |dir|
      home = File.join(dir, "home")
      make_secrets(home)
      yml = Fixtures::VALID_YML.sub("package: com.example.demo", "package: com.example.demo\n  rollout: 20")
                               .sub("bundle_id: com.example.demo", "bundle_id: com.example.demo\n  phased_release: true")
      config = StoreAutopilot::Config.load(make_app(dir, yml: yml))
      shell = fake_shell
      StoreAutopilot::Pipeline.new(config: config, shell: shell, home: home).submit
      assert_equal 0.2, shell.jobs["android promote"]["rollout"]
      assert_equal true, shell.jobs["ios submit"]["phased_release"]
    end
  end

  def test_rollout_command
    Dir.mktmpdir do |dir|
      home = File.join(dir, "home")
      make_secrets(home)
      config = StoreAutopilot::Config.load(make_app(dir))
      shell = fake_shell
      StoreAutopilot::Pipeline.new(config: config, shell: shell, home: home).rollout(50)
      assert_equal ["android rollout"], lanes(shell)
      assert_equal 0.5, shell.jobs["android rollout"]["rollout"]
      err = assert_raises(StoreAutopilot::Error) { StoreAutopilot::Pipeline.new(config: config, shell: shell, home: home).rollout(150) }
      assert_includes err.hint, "100 to finish"
    end
  end

  def test_submit_stops_when_app_review_is_missing_things
    Dir.mktmpdir do |dir|
      home = File.join(dir, "home")
      make_secrets(home)
      config = StoreAutopilot::Config.load(make_app(dir))
      shell = fake_shell(readiness: READY.merge(build: { number: "7", state: "PROCESSING" }, review_contact: false, content_rights: nil))
      StoreAutopilot::UI.out = (out = StringIO.new)
      err = assert_raises(StoreAutopilot::Error) { StoreAutopilot::Pipeline.new(config: config, shell: shell, home: home).submit }
      assert_includes err.message, "Not ready for App Review (3 problems"
      %w[still\ processing no\ contact\ person third-party\ content].each { |w| assert_includes out.string, w }
      assert_empty lanes(shell) # nothing submitted, Play not promoted
    end
  end

  def test_submit_sends_the_content_rights_answer
    Dir.mktmpdir do |dir|
      home = File.join(dir, "home")
      make_secrets(home)
      md = Fixtures::VALID_MD.sub("---\n", "---\nthird_party_content: false\n")
      config = StoreAutopilot::Config.load(make_app(dir, store_md: md))
      shell = fake_shell(readiness: READY.merge(content_rights: nil))
      StoreAutopilot::Pipeline.new(config: config, shell: shell, home: home).submit
      assert_equal "DOES_NOT_USE_THIRD_PARTY_CONTENT", shell.jobs["ios submit"]["content_rights"]
    end
  end

  def test_submit_runs_submit_and_promote
    Dir.mktmpdir do |dir|
      home = File.join(dir, "home")
      make_secrets(home)
      config = StoreAutopilot::Config.load(make_app(dir))
      shell = fake_shell
      StoreAutopilot::Pipeline.new(config: config, shell: shell, home: home).submit
      assert_equal ["ios submit", "android promote"], lanes(shell)
    end
  end
end
