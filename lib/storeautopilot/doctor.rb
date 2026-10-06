require "json"

module StoreAutopilot
  class Doctor
    Check = Struct.new(:status, :message, :hint)
    SENSITIVE = /(\.p8|\.jks|\.keystore|(\A|\/)key\.properties|google-services\.json|GoogleService-Info\.plist|(\A|\/)play\.json)\z/
    WORKFLOW = ".github/workflows/store.yml"
    MANUAL = [
      "Apple: create the app record in App Store Connect (name, bundle ID, SKU, primary language)",
      "Apple: fill in App Privacy labels; publish the privacy policy and support URLs",
      "Apple: agreements, tax and banking if you sell in-app purchases",
      "Google: create the app in Play Console and upload the first AAB by hand (turns on Play App Signing)",
      "Google: complete the App content forms (content rating, target audience, ads, data safety)",
      "Google: personal accounts created after Nov 2023 need a 14-day closed test with 12 testers before production"
    ].freeze

    def initialize(config_path:, shell:, home: Dir.home, online: false)
      @config_path = config_path
      @shell = shell
      @home = home
      @online = online
      @failed = false
    end

    def run
      report("Tools", tool_checks)
      config = begin
        Config.load(@config_path).tap { report("Config", [Check.new(:ok, "storeautopilot.yml")]) }
      rescue Error => e
        report("Config", [Check.new(:fail, e.message, e.hint)])
        nil
      end
      if config
        report("Store listing", listing_checks(config))
        report("Secrets", secret_checks(config))
        report("Flutter project", flutter_checks(config))
        report("Store requirements", Requirements.new(config: config, shell: @shell).findings(config.platforms))
        report("App Review risks", review_risks(config))
        report("Repository", repo_checks(config))
        report("GitHub runner", [runner_check(config)])
        report("Stores (online)", online_checks(config)) if @online
      end
      UI.step("One-time manual steps (no API for these)")
      MANUAL.each { |m| UI.info("• #{m}") }
      UI.step(@failed ? "Not ready — fix the ✗ items above" : "Ready")
      UI.info("Run `storeautopilot doctor --online` to also check the App Store and Google Play.") unless @online
      !@failed
    end

    def repo_checks(config)
      root = config.root
      list = []
      repo = JSON.parse(@shell.capture("gh", "repo", "view", "--json", "isPrivate", chdir: root)) rescue nil
      list << if repo.nil?
                Check.new(:warn, "could not ask GitHub whether the repo is private", "Is this repo on GitHub? Check `git remote -v` and `gh auth status`.")
              elsif repo["isPrivate"]
                Check.new(:ok, "repository is private")
              else
                Check.new(:fail, "repository is public — a self-hosted runner would run strangers' code on this Mac",
                          "Make the repo private or don't use StoreAutopilot's runner with it.")
              end
      tracked = @shell.capture("git", "ls-files", chdir: root, allow_failure: true).lines.map(&:strip).grep(SENSITIVE)
      tracked.each { |f| list << Check.new(:fail, "#{f} is committed to git", "git rm --cached #{f}, add it to .gitignore and rotate that key.") }
      loose = @shell.capture("git", "ls-files", "--others", "--exclude-standard", chdir: root, allow_failure: true).lines.map(&:strip).grep(SENSITIVE)
      loose.each { |f| list << Check.new(:warn, "#{f} is not in .gitignore", "Add it to .gitignore (storeautopilot init does this).") }
      list << Check.new(:ok, "no keys or credentials tracked by git") if tracked.empty? && loose.empty?
      workflow = File.join(root, WORKFLOW)
      list << if !File.file?(workflow)
                Check.new(:fail, "#{WORKFLOW} missing", "Run `storeautopilot init`.")
              elsif File.read(workflow).include?("pull_request")
                Check.new(:fail, "#{WORKFLOW} has a pull_request trigger", "Remove it: pull requests must never run on this Mac.")
              else
                Check.new(:ok, WORKFLOW)
              end
      heads = @shell.capture("git", "ls-remote", "--heads", "origin", "release", chdir: root, allow_failure: true)
      list << if heads.strip.empty?
                Check.new(:warn, "no `release` branch on origin yet", "Push one to trigger a release: git push origin HEAD:release")
              else
                Check.new(:ok, "`release` branch exists")
              end
      list
    end

    # Asks App Store Connect and Google Play what release would see: key access, app record, open version, first upload.
    def online_checks(config)
      secrets = Secrets.new(config.app_id, home: @home)
      return [Check.new(:warn, "skipped: keys are not ready (see Secrets above)")] if secrets.problems(config.platforms).any?
      fastlane = Fastlane.new(shell: @shell, workdir: Pipeline.work_dir(@home, config.app_id))
      list = []
      if config.ios?
        list.concat(store_findings do
          job = { bundle_id: config.ios[:bundle_id], asc_json: secrets.asc_json_path, asc_key: secrets.asc_key_path }
          StoreStatus.ios(fastlane.lane(:ios, :status, job, quiet: true), version: config.version_name, bundle_id: config.ios[:bundle_id])
        end)
      end
      if config.android?
        list.concat(store_findings do
          job = { package: config.android[:package], play_json: secrets.play_json_path }
          StoreStatus.android(fastlane.lane(:android, :status, job, quiet: true), track: config.android[:track])
        end)
      end
      list
    end

    private

    def store_findings
      yield
    rescue Error => e
      [Check.new(:fail, e.message, e.hint)]
    end

    def report(title, checks)
      UI.step(title)
      checks.each do |c|
        @failed = true if c.status == :fail
        case c.status
        when :ok then UI.ok(c.message)
        when :warn then UI.warn(c.message)
        else UI.bad(c.message)
        end
        UI.info("  → #{c.hint}") if c.hint && c.status != :ok
      end
    end

    def tool_checks
      list = %w[fastlane flutter xcrun git gh].map do |tool|
        @shell.available?(tool) ? Check.new(:ok, tool) : Check.new(:fail, "#{tool} not found", install_hint(tool))
      end
      list << (File.executable?(Compose::CHROME) ? Check.new(:ok, "Google Chrome") : Check.new(:fail, "Google Chrome not found", "Install Google Chrome."))
      list << if File.executable?(Env.sdk_tool("platform-tools/adb"))
                Check.new(:ok, "Android SDK")
              else
                Check.new(:warn, "Android SDK not found at #{Env.android_home}", "Install Android Studio or set ANDROID_HOME.")
              end
      list << (File.executable?(Env.keytool) ? Check.new(:ok, "Java (#{Env.java_home})") : Check.new(:warn, "Java not found", "Install Android Studio or set JAVA_HOME."))
      list << disk_check
      list
    end

    def encryption_check(config)
      return Check.new(:ok, "export compliance answered in Info.plist") if config.encryption_declared?
      return Check.new(:ok, "export compliance: no encryption, written to Info.plist on the next build") if config.ios[:uses_encryption] == false
      if config.ios[:uses_encryption] == true
        return Check.new(:warn, "app uses non-exempt encryption: each build needs export compliance documents",
                         "Answer it in App Store Connect → TestFlight for every build, or upload the documentation once.")
      end
      Check.new(:warn, "every TestFlight build will wait for an export compliance answer",
                "If the app only uses encryption built into iOS (HTTPS, Keychain…), set `ios.uses_encryption: false`.")
    end

    def review_risks(config)
      findings = Compliance.new(config: config, listing: Listing.load(config.listing_path)).findings
      findings.empty? ? [Check.new(:ok, "nothing found")] : findings
    rescue Error
      [Check.new(:warn, "skipped: store.md can't be read")]
    end

    def privacy_checks(config, listing)
      privacy = Privacy.from(listing)
      unless privacy
        return [Check.new(:warn, "store.md has no privacy declaration",
                          "Run `storeautopilot privacy`: it suggests one from your packages and shows what to tick in both stores.")]
      end
      gaps = privacy.sdk_gaps(Privacy.packages(config.flutter_dir))
      return [Check.new(:ok, "privacy declaration covers the known SDKs")] if gaps.empty?
      gaps.map { |g| Check.new(:warn, "privacy: #{g}, which isn't declared", "Both stores reject apps whose forms leave out SDK data.") }
    end

    def disk_check
      free = Disk.free_gb(@shell, @home)
      return Check.new(:warn, "could not read free disk space") unless free
      message = "#{free.round(1)} GB free on disk"
      return Check.new(:ok, message) if free >= Disk::COMFORTABLE_GB
      return Check.new(:warn, "#{message}; builds and simulators need room", Disk::HINT) if free >= Disk::MIN_GB
      Check.new(:fail, "#{message}; a release needs at least #{Disk::MIN_GB} GB", Disk::HINT)
    end

    def install_hint(tool)
      { "fastlane" => "brew install fastlane", "gh" => "brew install gh && gh auth login",
        "flutter" => "Install Flutter: https://docs.flutter.dev/get-started/install/macos",
        "xcrun" => "Install Xcode from the App Store" }.fetch(tool, "Install #{tool}")
    end

    def listing_checks(config)
      listing = Listing.load(config.listing_path).validate!(config)
      [Check.new(:ok, "store.md"), *listing.advice(config).map { |a| Check.new(:warn, a) }, *privacy_checks(config, listing)]
    rescue Error => e
      [Check.new(:fail, e.message, e.hint)]
    end

    def secret_checks(config)
      secrets = Secrets.new(config.app_id, home: @home)
      fixed = secrets.tighten!
      list = fixed.map { |p| Check.new(:ok, "tightened permissions on #{p}") }
      problems = secrets.problems(config.platforms)
      demo_problem = (secrets.demo_password(Listing.load(config.listing_path)).last rescue nil) if config.ios?
      problems += [[demo_problem, "Write the demo account's password into that file (it never goes into git)."]] if demo_problem
      list.concat(problems.map { |m, h| Check.new(:fail, m, h) })
      list << Check.new(:ok, "#{secrets.dir} complete and private") if problems.empty?
      list
    end

    def flutter_checks(config)
      pubspec = File.read(File.join(config.flutter_dir, "pubspec.yaml"))
      list = %w[integration_test flutter_driver].map do |dep|
        pubspec.include?("#{dep}:") ? Check.new(:ok, "#{dep} dev dependency") : Check.new(:fail, "#{dep} missing from pubspec.yaml", "Run `storeautopilot init`.")
      end
      if config.ios?
        list << Check.new(:ok, config.ipad? ? "runs on iPad: iPad screenshots will be captured too" : "iPhone only: no iPad screenshots needed")
        list << encryption_check(config)
      end
      missing = Screenshots.new(config: config, shell: @shell, devices: {}).missing_files
      list << (missing.empty? ? Check.new(:ok, "screenshot test") : Check.new(:fail, "missing #{missing.join(', ')}", "Run `storeautopilot init`."))
      if config.android?
        ks = config.android[:keystore_properties]
        list << if ks.nil?
                  Check.new(:warn, "android.keystore_properties not set; signing is checked on each release", "Set it in storeautopilot.yml to check it here.")
                elsif File.file?(ks)
                  Check.new(:ok, "Android signing config found")
                else
                  Check.new(:fail, "#{ks} not found", "Release builds would be debug-signed and rejected by Play.")
                end
      end
      list
    end

    def runner_check(config)
      data = JSON.parse(@shell.capture("gh", "api", "repos/{owner}/{repo}/actions/runners", chdir: config.root))
      ours = data["runners"].select { |r| r["labels"].any? { |l| l["name"] == "storeautopilot" } }
      return Check.new(:warn, "no runner registered", "Run `storeautopilot runner install`.") if ours.empty?
      return Check.new(:ok, "runner online (#{ours.first['name']})") if ours.any? { |r| r["status"] == "online" }
      Check.new(:warn, "runner registered but offline", "Run `storeautopilot runner install` again to restart it.")
    rescue Error, JSON::ParserError
      Check.new(:warn, "could not list runners", "Check `gh auth status` (needs repo admin access).")
    end
  end
end
