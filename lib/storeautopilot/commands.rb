module StoreAutopilot
  module Commands
    module_function

    # STOREAUTOPILOT_HOME exists for tests; normal runs use the real home folder.
    def home = ENV["STOREAUTOPILOT_HOME"] || Dir.home
    def log_dir = ENV["STOREAUTOPILOT_LOG_DIR"] || File.join(home, "Library", "Logs", "StoreAutopilot")
    def shell = Shell.new(env: Env.tools)
    def config(opts) = Config.load(opts[:config])

    def pipeline(opts)
      c = config(opts)
      Pipeline.new(config: c, shell: shell, platforms: opts[:only] ? [opts[:only]] : c.platforms,
                   dry_run: opts[:dry_run], skip_shots: opts[:skip_shots], fresh_shots: opts[:fresh_shots], home: home)
    end

    def init(_args, _opts) = Init.new(dir: Dir.pwd, shell: shell, home: home, prompt: ($stdin.tty? ? Prompt.new : nil)).run

    def import(_args, opts)
      c = config(opts)
      fastlane = Fastlane.new(shell: shell, workdir: Pipeline.work_dir(home, c.app_id))
      path = Importer.new(config: c, fastlane: fastlane, secrets: Secrets.new(c.app_id, home: home)).run
      return if File.basename(path) == "store.md"
      UI.info("store.md already exists, so nothing was overwritten. Compare the two; to use the import:")
      UI.info("  mv store.imported.md store.md")
    end

    def doctor(_args, opts)
      ok = Doctor.new(config_path: opts[:config], shell: shell, home: home, online: opts[:online]).run
      raise Error.new("Some checks failed.", hint: "Fix the ✗ items above and run `storeautopilot doctor` again.") unless ok
    end

    def shots(_args, opts)
      page = pipeline(opts).shots
      UI.ok("Store images in #{File.dirname(page)}")
      UI.ok("Preview: #{page}")
      system("open", page)
    end

    def preview(_args, opts)
      page = pipeline(opts).preview
      UI.ok("Preview: #{page}")
      system("open", page)
    end

    def release(_args, opts) = pipeline(opts).release
    def submit(_args, opts) = pipeline(opts).submit
    def status(_args, opts) = pipeline(opts).status

    def privacy(_args, opts)
      c = config(opts)
      listing = Listing.load(c.listing_path)
      packages = Privacy.packages(c.flutter_dir)
      declared = Privacy.from(listing)
      unless declared
        UI.step("No privacy declaration in store.md yet")
        UI.info("Add this to the front matter and adjust it (types: #{Privacy::TYPES.keys.join(', ')}):")
        UI.output("\n#{Privacy.suggestion(packages)}\n")
        return
      end
      raise Error.new("store.md privacy has problems:\n#{declared.problems.map { |p| "    - #{p}" }.join("\n")}") if declared.problems.any?
      if c.ios?
        UI.step("App Store Connect → your app → App Privacy")
        declared.apple_lines.each { |l| UI.info(l) }
      end
      if c.android?
        UI.step("Play Console → your app → App content → Data safety")
        declared.play_lines.each { |l| UI.info(l) }
      end
      gaps = declared.sdk_gaps(packages)
      UI.step(gaps.empty? ? "Covers what your packages are known to collect" : "Not declared, but your packages usually collect it")
      gaps.each { |g| UI.warn(g) }
    end

    def rollout(args, opts)
      percent = Float(args.first.to_s.delete_suffix("%"), exception: false)
      raise Error.new("Give the rollout percentage.", hint: "e.g. `storeautopilot rollout 50`, or 100 to finish.") unless percent
      pipeline(opts).rollout(percent % 1 == 0 ? percent.to_i : percent)
    end

    def runner(args, opts)
      raise Error.new("Unknown runner command.", hint: "Use `storeautopilot runner install`.") unless args.first == "install"
      RunnerInstall.new(root: File.dirname(File.expand_path(opts[:config])), shell: shell, home: home).run
    end
  end
end
