require "optparse"

module StoreAutopilot
  class CLI
    COMMANDS = %w[init import doctor privacy status reviews shots preview release submit rollout runner].freeze
    USAGE = <<~TXT
      Usage: storeautopilot <command> [options]

      Commands:
        init               Add StoreAutopilot files to this app repo
        import             Write store.md from the text already in App Store Connect and Google Play
        doctor             Check that everything is ready (and tighten secret permissions)
                           --online also asks App Store Connect and Google Play
        privacy            Show what to tick in App Privacy and Data safety, from store.md's privacy declaration
        status             Show what App Store Connect and Google Play hold for this app
        reviews            Newest reviews in both stores; `reviews reply ios:ID "text"` answers one
        shots              Capture and compose store screenshots locally, then open the preview
        preview            Show how both store pages will read, with the last screenshots
        release            Build, upload to TestFlight / Play, update the store listing
        submit             Submit the latest build for App Store review, promote Play to production
        rollout PERCENT    Widen a staged Google Play rollout (100 finishes it)
        rollout watch      Halt a staged Google Play rollout whose crash rate is too high
        runner install     Register this Mac as the repo's GitHub Actions runner

      Options:
        --config PATH       storeautopilot.yml path (default: ./storeautopilot.yml)
        --only ios|android  One platform only
        --skip-shots        release: don't capture or upload screenshots
        --fresh-shots       release/shots: capture again even if the app is unchanged
        --dry-run           release/submit: validate and print the plan only
        --online            doctor: check store access, the app records and the version
        --app DIR           init: one app of several in this repository (its folder)
    TXT

    def self.start(argv) = new.start(argv)

    def start(argv)
      opts = { config: "storeautopilot.yml", only: nil, dry_run: false, skip_shots: false, online: false, fresh_shots: false, app: nil }
      parser = OptionParser.new do |o|
        o.on("--config PATH") { |v| opts[:config] = v }
        o.on("--only PLATFORM", %w[ios android]) { |v| opts[:only] = v.to_sym }
        o.on("--skip-shots") { opts[:skip_shots] = true }
        o.on("--fresh-shots") { opts[:fresh_shots] = true }
        o.on("--dry-run") { opts[:dry_run] = true }
        o.on("--online") { opts[:online] = true }
        o.on("--app DIR") { |v| opts[:app] = v }
        o.on("-h", "--help") { opts[:help] = true }
        o.on("-v", "--version") { opts[:version] = true }
      end
      args = parser.parse(argv)
      command = args.shift
      if opts[:version]
        UI.out.puts("storeautopilot #{VERSION}")
        return 0
      end
      if opts[:help] || command.nil?
        UI.out.puts(USAGE)
        return 0
      end
      unless COMMANDS.include?(command)
        UI.out.puts("Unknown command: #{command}\n\n#{USAGE}")
        return 1
      end
      UI.start_log(Commands.log_dir, command)
      Commands.public_send(command, args, opts)
      0
    rescue OptionParser::ParseError => e
      UI.error(Error.new(e.message, hint: "Run `storeautopilot --help`."))
      1
    rescue Error => e
      UI.error(e)
      1
    rescue Interrupt
      UI.error(Error.new("Cancelled."))
      130
    rescue StandardError => e
      UI.log_only("#{e.class}: #{e.message}\n#{e.backtrace&.join("\n")}")
      UI.error(Error.new("Unexpected error: #{e.class}: #{e.message}",
                         hint: "This is a StoreAutopilot bug; please report it with the log below (check it for private details first)."))
      1
    ensure
      UI.close_log
    end
  end
end
