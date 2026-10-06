require "test_helper"

class PrivacyTest < Minitest::Test
  include Fixtures

  P = StoreAutopilot::Privacy
  DECLARED = <<~MD
    privacy:
      tracking: false
      encrypted_in_transit: true
      deletion_request: true
      collected:
        - { type: email, purposes: [account], linked: true }
        - { type: user_id, purposes: [account, app_functionality] }
        - { type: device_id, purposes: [advertising], linked: false, shared: true }
        - { type: crash_data, purposes: [analytics], optional: true }
  MD

  def privacy(yaml) = P.from(StoreAutopilot::Listing.parse(Fixtures::VALID_MD.sub("---\n", "---\n#{yaml}")))

  def test_apple_lines
    lines = privacy(DECLARED).apple_lines
    assert_equal "Data Collection: Yes", lines.first
    assert_includes lines, "Contact Info › Email Address — purposes: App Functionality; linked to the user: Yes; used for tracking: No"
    assert_includes lines, "Identifiers › Device ID — purposes: Third-Party Advertising; linked to the user: No; used for tracking: No"
  end

  def test_play_lines
    lines = privacy(DECLARED).play_lines
    assert_includes lines, "Is all of the user data collected by your app encrypted in transit? Yes"
    assert_includes lines, "Personal info › User IDs — collected; required; purposes: Account management, App functionality"
    assert_includes lines, "Device or other IDs › Device or other IDs — collected, shared; required; purposes: Advertising or marketing"
    assert_includes lines, "App info and performance › Crash logs — collected; optional; purposes: Analytics"
  end

  def test_nothing_collected
    p = privacy("privacy: { collected: [] }\n")
    assert_equal ["Data Collection: No, we do not collect data from this app"], p.apple_lines
    assert_equal ["Does your app collect or share any of the required user data types? No"], p.play_lines
  end

  def test_mistakes_fail_store_md_validation
    Dir.mktmpdir do |dir|
      md = Fixtures::VALID_MD.sub("---\n", "---\nprivacy:\n  tracking: maybe\n  collected:\n    - { type: shoe_size, purposes: [fun] }\n    - { type: email, purposes: [fun] }\n")
      err = assert_raises(StoreAutopilot::Error) { StoreAutopilot::Listing.parse(md).validate!(StoreAutopilot::Config.load(make_app(dir))) }
      %w[privacy.tracking shoe_size unknown\ purpose\ fun].each { |w| assert_includes err.message, w }
    end
  end

  def test_sdk_gaps_and_suggestion
    gaps = privacy(DECLARED).sdk_gaps(%w[google_mobile_ads firebase_crashlytics])
    assert_includes gaps, "google_mobile_ads usually collects product_interaction for advertising"
    refute(gaps.any? { |g| g.include?("device_id for advertising") })
    suggestion = P.suggestion(%w[purchases_flutter google_mobile_ads])
    parsed = privacy(suggestion + "\n")
    assert_empty parsed.problems
    assert_empty parsed.sdk_gaps(%w[purchases_flutter google_mobile_ads])
    assert_includes suggestion, "{ type: purchases, purposes: [app_functionality], linked: true, shared: false }"
  end

  def test_packages_come_from_pubspec_lock
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "pubspec.lock"), "packages:\n  google_mobile_ads:\n    dependency: direct\n  http:\n    dependency: direct\n")
      assert_equal ["google_mobile_ads"], P.packages(dir)
    end
  end
end
