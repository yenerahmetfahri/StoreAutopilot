require "fileutils"

module StoreAutopilot
  # Adds StoreAutopilot files to an app repo. Never overwrites existing files.
  class Init
    GITIGNORE = <<~TXT

      # StoreAutopilot: never commit signing keys or store credentials
      *.p8
      *.jks
      *.keystore
      key.properties
      google-services.json
      GoogleService-Info.plist
    TXT

    # language id => [App Store code, Google Play code]
    LANGUAGES = {
      "en" => %w[en-US en-US], "en-gb" => %w[en-GB en-GB], "de" => %w[de-DE de-DE], "fr" => %w[fr-FR fr-FR],
      "es" => %w[es-ES es-ES], "es-mx" => %w[es-MX es-419], "it" => %w[it it-IT], "pt" => %w[pt-BR pt-BR],
      "pt-pt" => %w[pt-PT pt-PT], "nl" => %w[nl-NL nl-NL], "tr" => %w[tr tr-TR], "ru" => %w[ru ru-RU],
      "pl" => %w[pl pl-PL], "sv" => %w[sv sv-SE], "da" => %w[da da-DK], "no" => %w[no no-NO], "fi" => %w[fi fi-FI],
      "ja" => %w[ja ja-JP], "ko" => %w[ko ko-KR], "zh" => %w[zh-Hans zh-CN], "zh-tw" => %w[zh-Hant zh-TW],
      "ar" => %w[ar-SA ar], "he" => %w[he iw-IL], "hi" => %w[hi hi-IN], "id" => %w[id id], "th" => %w[th th],
      "vi" => %w[vi vi], "uk" => %w[uk uk], "cs" => %w[cs cs-CZ], "el" => %w[el el-GR], "hu" => %w[hu hu-HU],
      "ro" => %w[ro ro], "ms" => %w[ms ms]
    }.freeze
    CATEGORIES = %w[BOOKS BUSINESS DEVELOPER_TOOLS EDUCATION ENTERTAINMENT FINANCE FOOD_AND_DRINK GAMES GRAPHICS_AND_DESIGN
                    HEALTH_AND_FITNESS LIFESTYLE MEDICAL MUSIC NAVIGATION NEWS PHOTO_AND_VIDEO PRODUCTIVITY REFERENCE
                    SHOPPING SOCIAL_NETWORKING SPORTS TRAVEL UTILITIES WEATHER].freeze

    # prompt: ask the developer (a Prompt); nil fills in placeholders to edit later.
    # dir: the repository's top folder. app: for a repository with several apps, the app's folder in it; that app's
    # files go there and its workflow (store-<app_id>.yml, branch release-<app_id>) next to the others.
    def initialize(dir:, shell:, home: Dir.home, prompt: nil, app: nil)
      @dir = File.expand_path(dir)
      @shell = shell
      @home = home
      @prompt = prompt
      @app = app && app.delete_suffix("/")
    end

    def run
      app_dir, flutter_rel = locate
      own = app_dir != "." # one of several apps in this repository
      flutter = File.join(@dir, app_dir, flutter_rel)
      vars = detect(flutter).merge(flutter_project: flutter_rel)
      vars = answers(vars)
      branch = own ? "release-#{vars[:app_id]}" : "release"
      vars.merge!(workflow_name: own ? "Store (#{vars[:app_id]})" : "Store", branch: branch,
                  config_arg: own ? " --config #{app_dir}/storeautopilot.yml" : "")
      UI.step("Adding StoreAutopilot files#{" for #{app_dir}" if own}")
      at = ->(rel) { own ? File.join(app_dir, rel) : rel }
      copy("storeautopilot.yml", vars, to: at.("storeautopilot.yml"))
      copy("store.md", vars, to: at.("store.md"))
      copy("storeautopilot/frame.html", nil, to: at.("storeautopilot/frame.html"))
      copy("storeautopilot/feature.html", nil, to: at.("storeautopilot/feature.html"))
      copy(".github/workflows/store.yml", vars, to: own ? ".github/workflows/store-#{vars[:app_id]}.yml" : ".github/workflows/store.yml")
      copy("flutter/#{Screenshots::TEST}", nil, to: at.(File.join(flutter_rel, Screenshots::TEST)))
      copy("flutter/#{Screenshots::DRIVER}", nil, to: at.(File.join(flutter_rel, Screenshots::DRIVER)))
      add_dev_dependencies(flutter)
      update_gitignore
      secrets = Secrets.new(vars[:app_id], home: @home)
      secrets.ensure_dir!
      UI.ok("secret folder #{secrets.dir} (private)")
      next_steps(secrets, branch, own ? app_dir : nil)
    end

    private

    DEFAULTS = { languages: ["en"], support_url: "https://example.com/support", privacy_url: "https://example.com/privacy",
                 category: nil, third_party_content: nil, uses_encryption: nil, background: "#111827" }.freeze

    # Turns the answers (or defaults) into template values.
    def answers(vars)
      a = DEFAULTS.merge(@prompt ? ask(vars) : {})
      locales = a[:languages].map do |id|
        apple, play = LANGUAGES.fetch(id) { UI.warn("#{id}: unknown language; check its store codes in storeautopilot.yml"); [id, id] }
        "  #{id}: { apple: #{apple}, play: #{play} }"
      end
      section = File.read(File.join(TEMPLATES, "app", "store_section.md"))
      vars.merge(
        support_url: a[:support_url], privacy_url: a[:privacy_url], background: a[:background],
        locales: locales.join("\n"),
        sections: a[:languages].map { |id| section.gsub("{{locale}}", id).gsub("{{app_name}}", vars[:app_name]) }.join("\n"),
        category_line: a[:category] ? "apple_category: #{a[:category]}" : "# apple_category: GAMES",
        content_line: a[:third_party_content].nil? ? "# third_party_content: false" : "third_party_content: #{a[:third_party_content]}",
        encryption_line: if a[:uses_encryption].nil?
                           "  # uses_encryption: false    # only standard iOS encryption (HTTPS…): no export compliance question per build"
                         else
                           "  uses_encryption: #{a[:uses_encryption]}"
                         end
      )
    end

    def ask(vars)
      UI.step("A few questions (Enter keeps the suggestion; everything can be changed later in the files)")
      a = {}
      vars[:app_name] = @prompt.ask("App name in the stores", default: vars[:app_name])
      a[:languages] = @prompt.ask("Languages, comma-separated (#{LANGUAGES.keys.first(8).join(', ')}…)", default: "en")
                             .split(",").map { |l| l.strip.downcase }.reject(&:empty?)
      a[:support_url] = @prompt.ask("Support page URL (a page where users can reach you)", default: DEFAULTS[:support_url])
      a[:privacy_url] = @prompt.ask("Privacy policy URL", default: DEFAULTS[:privacy_url])
      UI.info(CATEGORIES.each_with_index.map { |c, i| "#{i + 1}. #{c.downcase.tr('_', ' ')}" }.each_slice(6).map { |row| row.join("  ") }.join("\n  "))
      choice = @prompt.ask("App Store category (number, Enter to skip)").to_i
      a[:category] = CATEGORIES[choice - 1] if choice.between?(1, CATEGORIES.size)
      a[:third_party_content] = @prompt.yes?("Does the app show content it doesn't own (others' text, images, music)?")
      a[:uses_encryption] = @prompt.yes?("Does it use encryption beyond what iOS provides (HTTPS, Keychain)?")
      a[:background] = @prompt.ask("Brand color for the store images (#RRGGBB)", default: DEFAULTS[:background])
      a[:background] = DEFAULTS[:background] unless a[:background].match?(/\A#\h{6}\z/)
      a[:languages] = DEFAULTS[:languages] if a[:languages].empty?
      a
    end

    # [app folder relative to the repository ("." for a one-app repository), Flutter project relative to it]
    def locate
      if @app
        unless File.file?(File.join(@dir, @app, "pubspec.yaml"))
          raise Error.new("No Flutter project (pubspec.yaml) in #{@app}.", hint: "Give the app's folder, relative to the repository root.")
        end
        return [@app == "." ? "." : @app, "."]
      end
      return [".", "."] if File.file?(File.join(@dir, "pubspec.yaml"))
      found = Dir.glob("{*,*/*}/pubspec.yaml", base: @dir).map { |p| File.dirname(p) }
                 .reject { |d| d.split("/").any? { |part| part.start_with?(".") || %w[build example ios android].include?(part) } }.sort
      raise Error.new("No Flutter project (pubspec.yaml) found here or below.", hint: "Run init in your app repo root.") if found.empty?
      return [".", found.first] if found.size == 1 # one app in a subfolder: settings stay at the top
      choose_app(found)
    end

    def choose_app(found)
      unless @prompt
        raise Error.new("This repository has several Flutter apps: #{found.join(', ')}.",
                        hint: "Run `storeautopilot init --app <folder>` once for each app you want to release.")
      end
      UI.step("This repository has several Flutter apps")
      found.each_with_index { |d, i| UI.info("#{i + 1}. #{d}") }
      choice = @prompt.ask("Which one now? (run init again for the others)", default: "1").to_i
      raise Error.new("No such app.", hint: "Pick a number from the list.") unless choice.between?(1, found.size)
      [found[choice - 1], "."]
    end

    def detect(flutter)
      name = File.read(File.join(flutter, "pubspec.yaml"))[/^name:\s*(\S+)/, 1] || File.basename(@dir)
      pbx = Dir[File.join(flutter, "ios", "*.xcodeproj", "project.pbxproj")].first
      bundle = pbx && File.read(pbx).scan(/PRODUCT_BUNDLE_IDENTIFIER = "?([^";]+)"?;/).flatten.reject { |id| id.include?("Tests") }.first
      gradle = Dir[File.join(flutter, "android", "app", "build.gradle{,.kts}")].first
      package = gradle && File.read(gradle)[/applicationId\s*=?\s*"([^"]+)"/, 1]
      UI.warn("could not detect the iOS bundle id; edit storeautopilot.yml") unless bundle
      UI.warn("could not detect the Android package; edit storeautopilot.yml") unless package
      { app_id: name.downcase.tr("_", "-"), app_name: name.split("_").map(&:capitalize).join(" "),
        bundle_id: bundle || "com.example.app", package: package || "com.example.app", year: Time.now.year }
    end

    # vars: fill {{key}} placeholders (only for yml/md; HTML/Dart/workflow are copied verbatim).
    def copy(template, vars = nil, to: template)
      dest = File.join(@dir, to)
      return UI.info("kept #{to}") if File.exist?(dest)
      text = File.read(File.join(TEMPLATES, "app", template))
      text = text.gsub(/\{\{(\w+)\}\}/) { vars.fetch(Regexp.last_match(1).to_sym) } if vars
      FileUtils.mkdir_p(File.dirname(dest))
      File.write(dest, text)
      UI.ok("created #{to}")
    end

    def add_dev_dependencies(flutter)
      pubspec = File.read(File.join(flutter, "pubspec.yaml"))
      deps = %w[integration_test flutter_driver].reject { |d| pubspec.include?("#{d}:") }
      return if deps.empty?
      @shell.run("flutter", "pub", "add", *deps.map { |d| "dev:#{d}:{\"sdk\":\"flutter\"}" }, chdir: flutter)
      UI.ok("added #{deps.join(', ')} to dev_dependencies")
    end

    def update_gitignore
      path = File.join(@dir, ".gitignore")
      current = File.file?(path) ? File.read(path) : ""
      return if current.include?("# StoreAutopilot")
      File.write(path, current + GITIGNORE)
      UI.ok("added key/credential rules to .gitignore")
    end

    def next_steps(secrets, branch, app_dir)
      UI.step("Next")
      UI.info("1. Edit #{app_dir ? "#{app_dir}/" : ''}storeautopilot.yml and store.md")
      UI.info("2. Fill in #{Screenshots::TEST} (navigate to each screen)")
      UI.info("3. Put your keys in #{secrets.dir}: asc_key.p8, asc_key.json, play.json")
      UI.info("   (keys all your apps use can go once in #{secrets.shared})")
      UI.info("4. storeautopilot doctor")
      UI.info("5. storeautopilot shots   (preview screenshots)")
      UI.info("6. storeautopilot runner install#{" --config #{app_dir}/storeautopilot.yml" if app_dir}, then push to the `#{branch}` branch")
    end
  end
end
