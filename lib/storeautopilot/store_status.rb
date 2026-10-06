module StoreAutopilot
  # Reads what the fastlane `status` lanes report and turns it into findings for `doctor` and `release`.
  module StoreStatus
    Finding = Struct.new(:status, :message, :hint)
    ASC_KEY_HINT = "Check asc_key.p8 and asc_key.json, and that the key has the App Manager or Admin role."
    PLAY_HINT = "Check that the app exists in Play Console and that play.json's service account was invited with " \
                "release and store listing permissions."

    module_function

    def ios(status, version:, bundle_id:)
      return [failure("App Store Connect: #{status['error']}", ASC_KEY_HINT)] if status["error"]
      unless status["app"]
        return [failure("No app with bundle ID #{bundle_id} in App Store Connect.",
                        "Create the app record first: App Store Connect → Apps → + → New App.")]
      end
      live = status["live_version"]
      if live && !newer?(version, live)
        return [failure("Version #{version} is not higher than #{live}, which is already live on the App Store.",
                        "Raise `version:` in pubspec.yaml, e.g. to #{bump(live)}.")]
      end
      if status["pending_release_version"] == version
        return [failure("Version #{version} is approved and waiting to be released; it takes no new builds.",
                        "Release it in App Store Connect, or raise `version:` in pubspec.yaml to #{bump(version)}.")]
      end
      if status["in_review_version"] == version
        return [Finding.new(:warn, "Version #{version} is in App Review: a new build goes to TestFlight but does not " \
                                   "replace the one being reviewed.")]
      end
      [Finding.new(:ok, "App Store Connect: version #{version} accepts new builds#{" (live: #{live})" if live}")]
    end

    IPHONE_SETS = %w[APP_IPHONE_67 APP_IPHONE_65].freeze
    IPAD_SETS = %w[APP_IPAD_PRO_3GEN_129 APP_IPAD_PRO_129].freeze

    # Before `submit`: what App Review needs for this version (from the ios readiness lane).
    def ios_submission(r, config:, listing:)
      version = config.version_name
      return [failure("App Store Connect: #{r['error']}", ASC_KEY_HINT)] if r["error"]
      return [failure("No app with bundle ID #{config.ios[:bundle_id]} in App Store Connect.", "Create the app record first.")] unless r["app"]
      unless r["version"]
        return [failure("App Store version #{version} hasn't been prepared yet.",
                        "Run a release first; it creates the version with your text and screenshots.")]
      end
      list = [build_finding(r["build"], version)]
      config.locales.each do |id, codes|
        sets = r.dig("screenshots", codes[:apple]) || []
        list << failure("#{id}: no 6.9\" iPhone screenshots on the App Store version.", "Run a release without --skip-shots.") if (sets & IPHONE_SETS).empty?
        list << failure("#{id}: no 13\" iPad screenshots, which an iPad app needs.", "Run a release without --skip-shots.") if config.ipad? && (sets & IPAD_SETS).empty?
        list << failure("#{id}: no privacy policy URL in App Store Connect.", "Set privacy_url in store.md and run a release.") if r.dig("privacy_urls", codes[:apple]).to_s.empty?
      end
      unless r["review_contact"]
        list << failure("App Review has no contact person.",
                        "Add review_contact to store.md (sent with the next release), or fill it in App Store Connect → App Review.")
      end
      unanswered = Array(r["age_rating_unanswered"])
      if unanswered.any?
        shown = unanswered.first(6).map { |q| q.tr("_", " ") }.join(", ")
        shown += " and #{unanswered.size - 6} more" if unanswered.size > 6
        list << failure("Age rating questions not answered: #{shown}.",
                        "Answer them in App Store Connect → App Information → Age Rating (Apple added new ones in 2025), " \
                        "or set age_rating in store.md.")
      end
      if r["content_rights"].nil? && listing.content_rights.nil?
        list << failure("Apple needs to know whether the app shows third-party content.",
                        "Set `third_party_content: false` (or true) in store.md; it is sent when you submit.")
      end
      list.reject! { |f| f.status == :ok } if list.any? { |f| f.status == :fail }
      list
    end

    def build_finding(build, version)
      return failure("No TestFlight build of version #{version}.", "Run a release first.") unless build
      case build["state"]
      when "VALID" then Finding.new(:ok, "Build #{build['number']} of #{version} is processed and ready")
      when "PROCESSING" then failure("Build #{build['number']} is still processing at Apple.", "Try again in a few minutes.")
      else failure("Build #{build['number']} was not accepted by Apple (#{build['state']}).", "Apple emails the reason; fix it and release again.")
      end
    end

    def android(status, track:)
      tracks = status["tracks"] || {}
      errors = status["errors"] || {}
      return [failure("Google Play: #{errors.values.first || status['error'] || 'no track could be read'}", PLAY_HINT)] if tracks.empty?
      list = []
      if errors[track]
        list << Finding.new(:warn, "Google Play track `#{track}` could not be read: #{errors[track]}",
                            "Check android.track in storeautopilot.yml (internal, alpha, beta or production).")
      end
      newest = android_build_number(status)
      list << if newest.zero?
                Finding.new(:warn, "Nothing has been uploaded to Google Play yet.",
                            "Upload the first app bundle by hand in Play Console; Google requires it once.")
              else
                Finding.new(:ok, "Google Play: newest version code #{newest}")
              end
      list
    end

    def android_build_number(status) = (status["tracks"] || {}).values.flatten.map(&:to_i).max || 0

    # true if a is a higher version than b; unparseable versions never block a release.
    def newer?(a, b)
      Gem::Version.new(a) > Gem::Version.new(b)
    rescue ArgumentError
      true
    end

    # 1.4.2 → 1.4.3
    def bump(version)
      parts = version.to_s.split(".").map(&:to_i)
      parts << 0 while parts.size < 3
      parts[2] += 1
      parts.join(".")
    end

    def failure(message, hint) = Finding.new(:fail, message, hint)
  end
end
