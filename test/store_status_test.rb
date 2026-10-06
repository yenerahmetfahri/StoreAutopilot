require "test_helper"

class StoreStatusTest < Minitest::Test
  S = StoreAutopilot::StoreStatus

  def ios(status, version: "1.2.0") = S.ios(status, version: version, bundle_id: "com.example.demo")

  def test_ios_open_version
    finding, = ios({ "app" => true, "live_version" => "1.1.9" })
    assert_equal :ok, finding.status
    assert_includes finding.message, "1.2.0 accepts new builds (live: 1.1.9)"
  end

  def test_ios_first_version_of_a_new_app
    assert_equal :ok, ios({ "app" => true }).first.status
  end

  def test_ios_version_not_higher_than_live
    %w[1.2.0 1.10.0].each do |live|
      finding, = ios({ "app" => true, "live_version" => live })
      assert_equal :fail, finding.status, live
      assert_includes finding.hint, "pubspec.yaml"
    end
    assert_includes ios({ "app" => true, "live_version" => "1.10.0" }).first.hint, "1.10.1"
  end

  def test_ios_version_waiting_for_release_takes_no_builds
    finding, = ios({ "app" => true, "pending_release_version" => "1.2.0" })
    assert_equal :fail, finding.status
    assert_includes finding.hint, "1.2.1"
  end

  def test_ios_version_in_review_is_a_warning
    assert_equal :warn, ios({ "app" => true, "in_review_version" => "1.2.0" }).first.status
  end

  def test_ios_missing_app_and_lane_errors
    assert_includes ios({ "app" => false }).first.message, "No app with bundle ID com.example.demo"
    finding, = ios({ "error" => "401 Unauthorized" })
    assert_equal :fail, finding.status
    assert_includes finding.message, "401 Unauthorized"
    assert_includes finding.hint, "asc_key"
  end

  def test_ios_odd_version_strings_never_block
    assert_equal :ok, ios({ "app" => true, "live_version" => "1.0 beta" }).first.status
  end

  def test_android_reports_newest_code
    status = { "tracks" => { "internal" => [3], "alpha" => [9] }, "errors" => {} }
    assert_equal [:ok], S.android(status, track: "alpha").map(&:status)
    assert_equal 9, S.android_build_number(status)
  end

  def test_android_no_access_fails
    finding, = S.android({ "tracks" => {}, "errors" => { "internal" => "403 forbidden" } }, track: "internal")
    assert_equal :fail, finding.status
    assert_includes finding.message, "403 forbidden"
    assert_includes finding.hint, "play.json"
  end

  def test_android_first_upload_and_unreadable_track_are_warnings
    status = { "tracks" => { "internal" => [] }, "errors" => { "alpha" => "Track not found" } }
    findings = S.android(status, track: "alpha")
    assert_equal [:warn, :warn], findings.map(&:status)
    assert_includes findings.last.hint, "first app bundle by hand"
    assert_equal 0, S.android_build_number(status)
  end
end

class StoreStatusSubmissionTest < Minitest::Test
  include Fixtures
  S = StoreAutopilot::StoreStatus
  READY = JSON.parse(JSON.generate(PipelineTest::READY))

  def findings(readiness, md: Fixtures::VALID_MD, yml: Fixtures::VALID_YML)
    Dir.mktmpdir do |dir|
      config = StoreAutopilot::Config.load(make_app(dir, yml: yml))
      S.ios_submission(readiness, config: config, listing: StoreAutopilot::Listing.parse(md))
    end
  end

  def test_ready
    assert_equal [:ok], findings(READY).map(&:status)
  end

  def test_version_not_prepared
    finding, = findings(READY.merge("version" => nil))
    assert_includes finding.message, "hasn't been prepared"
  end

  def test_each_missing_piece_is_reported_and_only_failures_are_listed
    r = READY.merge("build" => nil, "screenshots" => {}, "privacy_urls" => {}, "age_rating_unanswered" => %w[messaging_and_chat user_generated_content])
    messages = findings(r).map(&:message).join("\n")
    %w[No\ TestFlight\ build 6.9" privacy\ policy messaging\ and\ chat,\ user\ generated\ content].each { |w| assert_includes messages, w }
    assert(findings(r).all? { |f| f.status == :fail })
  end

  def test_ipad_apps_need_ipad_screenshots
    Dir.mktmpdir do |dir|
      config = StoreAutopilot::Config.load(make_app(dir, yml: Fixtures::VALID_YML.sub("bundle_id: com.example.demo", "bundle_id: com.example.demo\n  ipad: true")))
      f = S.ios_submission(READY, config: config, listing: StoreAutopilot::Listing.parse(Fixtures::VALID_MD))
      assert_includes f.map(&:message).join, "13\" iPad"
    end
  end

  def test_rejected_build
    finding, = findings(READY.merge("build" => { "number" => "9", "state" => "INVALID" }))
    assert_includes finding.message, "not accepted"
  end
end
