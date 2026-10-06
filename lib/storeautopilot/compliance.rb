module StoreAutopilot
  # Checks behind the most common rejections that can be seen from the project itself: missing purpose strings and
  # SDK ids (a crash on first use or at launch), tracking without its prompt text, sign-in without account deletion.
  # A certain crash fails; the rest warns.
  class Compliance
    Finding = StoreStatus::Finding
    SIGN_IN = %w[firebase_auth google_sign_in sign_in_with_apple supabase_flutter flutter_facebook_auth amplify_auth_cognito].freeze
    # package => Info.plist keys it needs ([key, :fail | :warn])
    PURPOSE_STRINGS = {
      "image_picker" => [["NSPhotoLibraryUsageDescription", :warn], ["NSCameraUsageDescription", :warn]],
      "camera" => [["NSCameraUsageDescription", :warn], ["NSMicrophoneUsageDescription", :warn]],
      "mobile_scanner" => [["NSCameraUsageDescription", :warn]],
      "geolocator" => [["NSLocationWhenInUseUsageDescription", :warn]],
      "location" => [["NSLocationWhenInUseUsageDescription", :warn]],
      "local_auth" => [["NSFaceIDUsageDescription", :warn]],
      "record" => [["NSMicrophoneUsageDescription", :warn]],
      "flutter_contacts" => [["NSContactsUsageDescription", :warn]],
      "photo_manager" => [["NSPhotoLibraryUsageDescription", :warn]],
      "app_tracking_transparency" => [["NSUserTrackingUsageDescription", :fail]],
      "google_mobile_ads" => [["GADApplicationIdentifier", :fail]]
    }.freeze
    ADMOB_ANDROID = "com.google.android.gms.ads.APPLICATION_ID"

    def initialize(config:, listing:, platforms: config.platforms)
      @config = config
      @listing = listing
      @platforms = platforms & config.platforms
    end

    def findings
      packages = installed_packages
      list = []
      list.concat(ios_findings(packages)) if @platforms.include?(:ios)
      list.concat(android_findings(packages)) if @platforms.include?(:android)
      list.concat(account_deletion(packages))
      list
    end

    private

    def installed_packages
      lock = File.join(@config.flutter_dir, "pubspec.lock")
      File.file?(lock) ? File.read(lock).scan(/^  (\w+):$/).flatten : []
    end

    def file(*parts)
      path = File.join(@config.flutter_dir, *parts)
      File.file?(path) ? File.read(path) : ""
    end

    def ios_findings(packages)
      plist = file("ios", "Runner", "Info.plist")
      needs = packages.flat_map { |pkg| (PURPOSE_STRINGS[pkg] || []).map { |key, level| [pkg, key, level] } }
      tracking = Privacy.from(@listing)&.flag("tracking")
      needs << ["privacy.tracking", "NSUserTrackingUsageDescription", :fail] if tracking
      list = needs.uniq { |_, key, _| key }.reject { |_, key, _| plist.include?("<key>#{key}</key>") }.map do |pkg, key, level|
        Finding.new(level, "ios/Runner/Info.plist has no #{key}, which #{pkg} needs",
                    level == :fail ? "Without it the app crashes or is rejected; add it to Info.plist." : "iOS stops the app when it asks for that permission without this text.")
      end
      unless File.file?(File.join(@config.flutter_dir, "ios", "Runner", "PrivacyInfo.xcprivacy"))
        list << Finding.new(:warn, "no ios/Runner/PrivacyInfo.xcprivacy",
                            "Apple wants a privacy manifest when your own code uses required-reason APIs or tracks; " \
                            "Xcode: File › New › File › App Privacy.")
      end
      list
    end

    def android_findings(packages)
      return [] unless packages.include?("google_mobile_ads")
      manifest = file("android", "app", "src", "main", "AndroidManifest.xml")
      return [] if manifest.include?(ADMOB_ANDROID)
      [Finding.new(:fail, "AndroidManifest.xml has no #{ADMOB_ANDROID}, which google_mobile_ads needs",
                   "Without it the app crashes at launch; add the meta-data with your AdMob app id.")]
    end

    # Guideline 5.1.1(v): apps with sign-in must let users delete their account inside the app.
    def account_deletion(packages)
      used = packages & SIGN_IN
      return [] if used.empty? || !@platforms.include?(:ios)
      return [] if @listing.meta["review_notes"].to_s.match?(/delet/i)
      [Finding.new(:warn, "#{used.join(', ')}: Apple requires account deletion inside the app",
                   "Offer it in the app and say where in review_notes (e.g. \"Settings → Delete account\").")]
    end

  end
end
