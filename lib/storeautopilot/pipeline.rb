require "fileutils"

module StoreAutopilot
  class Pipeline
    def self.work_dir(home, app_id) = File.join(home, "Library", "Caches", "StoreAutopilot", app_id)

    def initialize(config:, shell:, platforms: config.platforms, dry_run: false, skip_shots: false, fresh_shots: false,
                   home: Dir.home, screenshots: nil, compose: nil)
      @config = config
      @shell = shell
      @platforms = platforms & config.platforms
      @dry_run = dry_run
      @skip_shots = skip_shots
      @fresh_shots = fresh_shots
      @home = home
      @secrets = Secrets.new(config.app_id, home: home)
      @state = State.new(@secrets.state_path)
      @work = Pipeline.work_dir(home, config.app_id)
      @fastlane = Fastlane.new(shell: shell, workdir: @work)
      @builder = Builder.new(config: config, shell: shell)
      @screenshots = screenshots || Screenshots.new(config: config, shell: shell)
      @compose = compose || Compose.new(shell: shell)
    end

    def work_dir = @work
    def store_dir = File.join(@work, "store")

    def release
      listing = preflight
      check_requirements
      return plan(release_plan) if @dry_run
      notifying("Release") do
        Disk.check!(@shell, @home)
        FileUtils.rm_rf(store_dir)
        id = release_id
        uploaded = uploaded_builds(id)
        number = next_build_number
        number = uploaded.values.max if uploaded.any? # a re-run continues with the build number already in use
        @state.record("build_number", number)
        UI.step("Version #{@config.version_name} (#{number})")
        @platforms.each do |p|
          capture_and_compose(p, listing) unless @skip_shots
          capture_and_compose(:ipad, listing) if p == :ios && @config.ipad? && !@skip_shots
          if uploaded.key?(p.to_s)
            UI.step("#{p == :ios ? 'iOS' : 'Android'}: build #{number} of this commit is already uploaded; not building it again")
          else
            p == :ios ? upload_ios(listing, number) : upload_android(listing, number)
            remember_upload(id, p, number)
          end
          p == :ios ? listing_ios(listing) : listing_android(listing, number)
        end
        "Version #{@config.version_name} (#{number}) uploaded: #{@platforms.join(', ')}"
      end
    end

    def submit
      listing = preflight
      check_ios_submission(listing) if @platforms.include?(:ios)
      if @dry_run
        return plan(@platforms.map { |p| p == :ios ? "submit the latest TestFlight build for App Store review#{' (phased release)' if @config.ios[:phased_release]}" : "promote #{@config.android[:track]} → production#{rollout_note}" })
      end
      notifying("Submit") do
        if @platforms.include?(:ios)
          UI.step("iOS: submitting for App Store review")
          out = @fastlane.lane(:ios, :submit, ios_job(version: @config.version_name, phased_release: @config.ios[:phased_release],
                                                      content_rights: listing.content_rights))
          UI.ok("Build #{out['build_number']} submitted")
        end
        if @platforms.include?(:android)
          UI.step("Android: promoting #{@config.android[:track]} → production#{rollout_note}")
          out = @fastlane.lane(:android, :promote, android_job(track: @config.android[:track], rollout: @config.android[:rollout] / 100.0))
          UI.ok("Version code #{out['version_code']} promoted")
        end
        "Submitted: #{@platforms.join(', ')}"
      end
    end

    # What the stores currently hold for this app, without opening either console.
    def status
      problems = @secrets.problems(@platforms)
      raise Error.new("Secrets are not ready: #{problems.first.first}", hint: "Run `storeautopilot doctor`.") if problems.any?
      if @platforms.include?(:ios)
        UI.step("App Store (#{@config.ios[:bundle_id]})")
        s = @fastlane.lane(:ios, :status, ios_job, quiet: true, retries: 1)
        if s["app"]
          { "live" => s["live_version"], "in review" => s["in_review_version"], "approved, not released" => s["pending_release_version"],
            "newest TestFlight build" => (s["build_number"].to_i.positive? ? s["build_number"] : nil) }
            .each { |label, value| UI.info("#{label.ljust(24)}#{value || '—'}") }
        end
        show_findings(StoreStatus.ios(s, version: @config.version_name, bundle_id: @config.ios[:bundle_id]))
      end
      if @platforms.include?(:android)
        UI.step("Google Play (#{@config.android[:package]})")
        s = @fastlane.lane(:android, :status, android_job, quiet: true, retries: 1)
        (s["tracks"] || {}).each { |track, codes| UI.info("#{track.ljust(24)}#{codes.empty? ? '—' : "version code #{codes.max}"}") }
        show_findings(StoreStatus.android(s, track: @config.android[:track]))
      end
      nil
    end

    # Raises (or completes, at 100) the share of users a staged Google Play production rollout reaches.
    def rollout(percent)
      raise Error.new("`rollout` is for Google Play; storeautopilot.yml has no android section.") unless @config.android?
      unless Config.percent?(percent)
        raise Error.new("Rollout must be a percentage above 0 and up to 100.", hint: "e.g. `storeautopilot rollout 50`, or 100 to finish.")
      end
      @platforms = [:android]
      preflight
      return plan(["set the Google Play production rollout to #{percent}%"]) if @dry_run
      notifying("Rollout") do
        UI.step("Android: production rollout → #{percent}%")
        @fastlane.lane(:android, :rollout, android_job(rollout: percent / 100.0))
        percent >= 100 ? "Google Play rollout complete" : "Google Play rollout at #{percent}%"
      end
    end

    # Local preview: capture + compose only.
    def shots
      listing = Listing.load(@config.listing_path).validate!(@config)
      Disk.check!(@shell, @home)
      FileUtils.rm_rf(store_dir)
      @platforms.each do |p|
        capture_and_compose(p, listing)
        capture_and_compose(:ipad, listing) if p == :ios && @config.ipad?
      end
      Preview.new(config: @config, listing: listing, store_dir: store_dir).write
    end

    # The preview page alone, with the images from the last `shots` (if any).
    def preview
      Preview.new(config: @config, listing: Listing.load(@config.listing_path), store_dir: store_dir).write
    end

    private

    def preflight
      listing = Listing.load(@config.listing_path).validate!(@config)
      listing.advice(@config).each { |a| UI.warn(a) }
      problems = @secrets.problems(@platforms)
      if @platforms.include?(:ios)
        _, demo_problem = @secrets.demo_password(listing)
        problems += [[demo_problem, nil]] if demo_problem
      end
      if problems.any?
        raise Error.new("Secrets are not ready:\n#{problems.map { |m, _| "    - #{m}" }.join("\n")}", hint: "Run `storeautopilot doctor`.")
      end
      %w[fastlane flutter].each do |tool|
        raise Error.new("`#{tool}` not found on PATH.", hint: "Run `storeautopilot doctor`.") unless @shell.available?(tool)
      end
      listing
    end

    def rollout_note
      percent = @config.android[:rollout]
      percent < 100 ? " (staged rollout to #{percent}%)" : ""
    end

    def plan(steps)
      UI.step("Dry run — nothing will be built or uploaded")
      steps.each { |s| UI.info("would #{s}") }
      nil
    end

    def release_plan
      shots = "#{@config.screenshots.size} screenshot(s) × #{@config.locales.size} locale(s)"
      steps = ["check the version and read the latest build numbers from #{@platforms.map { |p| p == :ios ? 'TestFlight' : 'Google Play' }.join(' and ')}"]
      @platforms.each do |p|
        unless @skip_shots
          steps << "capture and compose #{shots} on the #{p == :ios ? 'iPhone simulator' : 'Android emulator'}"
          steps << "capture and compose #{shots} on the iPad simulator" if p == :ios && @config.ipad?
        end
        steps << (p == :ios ? "build the iOS app and upload it to TestFlight" : "build the Android app bundle and upload it to the #{@config.android[:track]} track")
        steps << "update the #{p == :ios ? 'App Store' : 'Google Play'} listing if text or images changed"
      end
      steps
    end

    # Runs a store-changing command; reports the outcome as a macOS notification and a GitHub job summary.
    def notifying(what)
      first_step = UI.steps.size
      first_warning = UI.warnings.size
      report = ->(**result) { Summary.write(steps: UI.steps[first_step..], warnings: UI.warnings[first_warning..], **result) }
      message = yield
      report.call(title: "#{what}: #{message}", ok: true)
      UI.step("Done")
      UI.ok(message)
      UI.notify("✓ #{message}")
    rescue StandardError, Interrupt => e
      report.call(title: "#{what} failed", ok: false, detail: e.message, hint: (e.hint if e.respond_to?(:hint)))
      UI.notify("✗ #{what} failed: #{e.message.lines.first.to_s.strip}")
      raise
    end

    # Asks the stores for their state before anything is built: a closed version or a missing app fails here, in
    # seconds, instead of at upload time.
    def next_build_number
      UI.step("Checking the stores")
      numbers = [@state["build_number"].to_i]
      if @platforms.include?(:ios)
        status = @fastlane.lane(:ios, :status, ios_job, retries: 2)
        enforce!(StoreStatus.ios(status, version: @config.version_name, bundle_id: @config.ios[:bundle_id]))
        numbers << status["build_number"].to_i
      end
      if @platforms.include?(:android)
        status = @fastlane.lane(:android, :status, android_job, retries: 2)
        enforce!(StoreStatus.android(status, track: @config.android[:track]))
        numbers << StoreStatus.android_build_number(status)
      end
      numbers.max + 1
    end

    # Read-only; runs for --dry-run too, so it doubles as "is this version ready for review?".
    def check_ios_submission(listing)
      UI.step("Checking that version #{@config.version_name} is ready for App Review")
      readiness = @fastlane.lane(:ios, :readiness, ios_job(version: @config.version_name), quiet: true, retries: 1)
      findings = StoreStatus.ios_submission(readiness, config: @config, listing: listing)
      show_findings(findings)
      failed = findings.select { |f| f.status == :fail }
      return if failed.empty?
      raise Error.new("Not ready for App Review (#{failed.size} problem#{'s' if failed.size > 1} above).",
                      hint: "Fix them, then run submit again. `storeautopilot submit --dry-run` checks without submitting.")
    end

    # Store rules in force (target SDK, Xcode, minimum iOS) are checked before building, not discovered at upload.
    def check_requirements
      findings = Requirements.new(config: @config, shell: @shell).findings(@platforms)
      findings.select { |f| f.status == :warn }.each { |f| UI.warn(f.message) }
      failed = findings.find { |f| f.status == :fail }
      raise Error.new("Not accepted by the store: #{failed.message}", hint: failed.hint) if failed
    end

    def show_findings(findings)
      findings.each do |f|
        { ok: :ok, warn: :warn, fail: :bad }.fetch(f.status).then { |level| UI.public_send(level, f.message) }
        UI.info("  → #{f.hint}") if f.hint && f.status != :ok
      end
    end

    def enforce!(findings)
      findings.each do |f|
        UI.ok(f.message) if f.status == :ok
        UI.warn(f.message) if f.status == :warn
      end
      failed = findings.find { |f| f.status == :fail }
      raise Error.new(failed.message, hint: failed.hint) if failed
    end

    # Captures unless the app is unchanged since the last capture on this Mac (see ShotInputs); composing always runs,
    # since captions and templates may have changed.
    def capture_and_compose(target, listing)
      UI.step("#{target}: screenshots")
      raw = File.join(@work, "raw")
      inputs = ShotInputs.new(config: @config, shell: @shell).digest(target)
      key = "shot_inputs_#{target}"
      if !@fresh_shots && inputs && @state[key] == inputs && raw_complete?(raw, target)
        UI.ok("app unchanged since the last capture; reusing those screenshots (--fresh-shots to retake)")
      else
        @state.record(key, nil) if @state[key]
        @screenshots.capture(target, raw)
        @state.record(key, inputs) if inputs
      end
      out = File.join(store_dir, target == :ipad ? "ios" : target.to_s)
      Images.new(config: @config, listing: listing, compose: @compose).build(target, raw_dir: raw, out_dir: out)
    end

    def raw_complete?(raw, target)
      @config.locales.keys.product(@config.screenshots).all? { |locale, shot| File.file?(File.join(raw, target.to_s, locale, "#{shot}.png")) }
    end

    # "<commit>:<version>" of a clean git checkout, else nil. A re-run of the same release (e.g. GitHub's "Re-run
    # jobs" after Android failed) skips the builds that already reached the stores.
    def release_id
      sha = @shell.capture("git", "rev-parse", "HEAD", chdir: @config.root, allow_failure: true).strip
      return nil unless sha.match?(/\A\h{40}\z/)
      return nil unless @shell.capture("git", "status", "--porcelain", chdir: @config.root, allow_failure: true).strip.empty?
      "#{sha}:#{@config.version_name}"
    end

    # platform name => build number already uploaded for this release id
    def uploaded_builds(id)
      return {} unless id
      (@state["uploaded"] || {}).select { |p, entry| entry["id"] == id && @platforms.map(&:to_s).include?(p) }
                                .transform_values { |entry| entry["build_number"] }
    end

    def remember_upload(id, platform, number)
      return unless id
      @state.record("uploaded", (@state["uploaded"] || {}).merge(platform.to_s => { "id" => id, "build_number" => number }))
    end

    def upload_ios(listing, number)
      UI.step("iOS: build and upload to TestFlight")
      workspace = @builder.ios(build_number: number)
      notes = @config.ios[:testflight_notes] ? listing.testflight_notes(@config) : {}
      @fastlane.lane(:ios, :upload, ios_job(workspace: workspace, build_dir: File.join(@work, "build"), testflight_notes: notes))
    end

    def listing_ios(listing)
      meta = listing.write_apple(File.join(store_dir, "ios", "metadata"), @config, demo_password: @secrets.demo_password(listing).first)
      shots = File.join(store_dir, "ios", "screenshots")
      text_digest = State.digest(meta)
      shots_digest = State.digest(shots)
      text = @state.changed?("ios_text", text_digest)
      images = !@skip_shots && @state.changed?("ios_shots", shots_digest)
      return UI.ok("App Store listing unchanged") unless text || images
      UI.step("iOS: updating App Store listing (#{[('text' if text), ('screenshots' if images)].compact.join(' + ')})")
      @fastlane.lane(:ios, :metadata, ios_job(version: @config.version_name, metadata_path: (meta if text),
                                              screenshots_path: (shots if images),
                                              age_rating: listing.write_age_rating(File.join(@work, "age_rating.json"))),
                     retries: 1)
      @state.record("ios_text", text_digest) if text
      @state.record("ios_shots", shots_digest) if images
    end

    # The bundle goes up with its release notes (changelogs in the metadata folder).
    def upload_android(listing, number)
      UI.step("Android: build and upload to #{@config.android[:track]}")
      aab = @builder.android(build_number: number)
      @fastlane.lane(:android, :upload, android_job(track: @config.android[:track], release_status: @config.android[:release_status],
                                                    aab: aab, metadata_path: play_metadata(listing, number)))
    end

    def play_metadata(listing, number) = listing.write_play(File.join(store_dir, "android", "metadata"), @config, version_code: number)

    def data_safety
      csv = @config.data_safety_csv
      return unless csv
      digest = State.digest(File.dirname(csv), only: /\Adata_safety\.csv\z/)
      return UI.ok("Data safety form unchanged") unless @state.changed?("android_data_safety", digest)
      UI.step("Android: updating the Data safety form")
      @fastlane.lane(:android, :data_safety, android_job(csv: csv), retries: 1)
      @state.record("android_data_safety", digest)
    end

    def listing_android(listing, number)
      data_safety
      meta = play_metadata(listing, number)
      text_digest = State.digest(meta, except: %r{(\A|/)(changelogs|images)/})
      images_digest = State.digest(meta, only: %r{(\A|/)images/})
      text = @state.changed?("android_text", text_digest)
      images = !@skip_shots && @state.changed?("android_images", images_digest)
      return UI.ok("Google Play listing unchanged") unless text || images
      UI.step("Android: updating Google Play listing (#{[('text' if text), ('images' if images)].compact.join(' + ')})")
      @fastlane.lane(:android, :metadata, android_job(metadata_path: meta, text: text, images: images,
                                                     track: @config.android[:track]), retries: 1)
      @state.record("android_text", text_digest) if text
      @state.record("android_images", images_digest) if images
    end

    def ios_job(**extra)
      { bundle_id: @config.ios[:bundle_id], asc_json: @secrets.asc_json_path, asc_key: @secrets.asc_key_path }.merge(extra)
    end

    def android_job(**extra)
      { package: @config.android[:package], play_json: @secrets.play_json_path }.merge(extra)
    end
  end
end
