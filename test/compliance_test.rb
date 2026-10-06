require "test_helper"

class ComplianceTest < Minitest::Test
  include Fixtures

  def project(dir, packages: [], plist_keys: [], manifest: "", privacy_manifest: true, md: Fixtures::VALID_MD)
    config = StoreAutopilot::Config.load(make_app(dir, store_md: md))
    root = config.flutter_dir
    File.write(File.join(root, "pubspec.lock"), "packages:\n" + packages.map { |p| "  #{p}:\n    dependency: direct\n" }.join)
    FileUtils.mkdir_p(File.join(root, "ios/Runner"))
    File.write(File.join(root, "ios/Runner/Info.plist"), "<dict>" + plist_keys.map { |k| "<key>#{k}</key><string>x</string>" }.join + "</dict>")
    FileUtils.touch(File.join(root, "ios/Runner/PrivacyInfo.xcprivacy")) if privacy_manifest
    FileUtils.mkdir_p(File.join(root, "android/app/src/main"))
    File.write(File.join(root, "android/app/src/main/AndroidManifest.xml"), manifest)
    [config, StoreAutopilot::Listing.load(config.listing_path)]
  end

  def findings(*args, **kw)
    Dir.mktmpdir do |dir|
      config, listing = project(dir, *args, **kw)
      StoreAutopilot::Compliance.new(config: config, listing: listing).findings.map { |f| [f.status, f.message] }
    end
  end

  def test_clean_project
    assert_empty findings
  end

  def test_admob_ids_missing_on_both_platforms_fail
    result = findings(packages: %w[google_mobile_ads])
    assert_includes result, [:fail, "ios/Runner/Info.plist has no GADApplicationIdentifier, which google_mobile_ads needs"]
    assert(result.any? { |s, m| s == :fail && m.include?("com.google.android.gms.ads.APPLICATION_ID") })
    ok = findings(packages: %w[google_mobile_ads], plist_keys: %w[GADApplicationIdentifier],
                  manifest: '<meta-data android:name="com.google.android.gms.ads.APPLICATION_ID" android:value="x"/>')
    assert_empty ok
  end

  def test_tracking_needs_its_prompt_text
    md = Fixtures::VALID_MD.sub("---\n", "---\nprivacy: { tracking: true, collected: [] }\n")
    assert_includes findings(md: md), [:fail, "ios/Runner/Info.plist has no NSUserTrackingUsageDescription, which privacy.tracking needs"]
  end

  def test_permission_texts_warn
    assert_includes findings(packages: %w[local_auth]), [:warn, "ios/Runner/Info.plist has no NSFaceIDUsageDescription, which local_auth needs"]
  end

  def test_sign_in_needs_account_deletion_in_review_notes
    assert(findings(packages: %w[sign_in_with_apple]).any? { |_, m| m.include?("account deletion") })
    md = Fixtures::VALID_MD.sub("---\n", "---\nreview_notes: Delete the account in Settings → Delete account.\n")
    assert_empty findings(packages: %w[sign_in_with_apple], md: md)
  end

  def test_missing_privacy_manifest_warns
    assert_equal [[:warn, "no ios/Runner/PrivacyInfo.xcprivacy"]], findings(privacy_manifest: false)
  end

  def test_android_only_release_ignores_ios_files
    Dir.mktmpdir do |dir|
      config, listing = project(dir, packages: %w[google_mobile_ads local_auth],
                                     manifest: '<meta-data android:name="com.google.android.gms.ads.APPLICATION_ID"/>')
      assert_empty StoreAutopilot::Compliance.new(config: config, listing: listing, platforms: [:android]).findings
    end
  end
end
