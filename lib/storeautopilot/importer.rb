require "yaml"

module StoreAutopilot
  # Builds store.md from what App Store Connect and Google Play show today, for apps that are already published.
  # Never overwrites: an existing store.md is left alone and the result goes to store.imported.md.
  class Importer
    APPLE_FIELDS = %w[name subtitle keywords promotional_text description release_notes].freeze
    PLAY_FIELDS = %w[name short_description description].freeze
    URLS = %w[support_url privacy_url marketing_url].freeze

    def initialize(config:, fastlane:, secrets:)
      @config = config
      @fastlane = fastlane
      @secrets = secrets
    end

    # Returns the path written.
    def run
      apple = fetch(:ios) { { bundle_id: @config.ios[:bundle_id], asc_json: @secrets.asc_json_path, asc_key: @secrets.asc_key_path } }
      play = fetch(:android) { { package: @config.android[:package], play_json: @secrets.play_json_path } }
      raise Error.new("Nothing to import: no store could be read.", hint: "Run `storeautopilot doctor --online`.") unless apple || play
      text = self.class.build(config: @config, apple: apple || {}, play: play || {}, existing: existing_listing) { |w| UI.warn(w) }
      path = File.exist?(@config.listing_path) ? File.join(@config.root, "store.imported.md") : @config.listing_path
      File.write(path, text)
      check(path)
      path
    end

    # apple / play: lane results ({"locales" => {store code => fields}, ...}); existing: the current Listing, whose
    # captions are kept. Warnings (store text that can't be represented) are yielded.
    def self.build(config:, apple:, play:, existing: nil)
      apple_locales = apple["locales"] || {}
      play_locales = play["locales"] || {}
      first = apple_locales[config.locales.values.first&.fetch(:apple)] || {}
      front = URLS.to_h { |k| [k, first[k]] }
      front["copyright"] = apple["copyright"]
      front["apple_category"] = apple["apple_category"]
      front.merge!((existing&.meta || {}).slice("review_notes", "review_contact", "review_demo_user", "age_rating"))
      sections = config.locales.map do |id, codes|
        a = apple_locales[codes[:apple]] || {}
        p = play_locales[codes[:play]] || {}
        yield "#{id}: App Store has no #{codes[:apple]} text" if config.ios? && a.empty? && block_given?
        yield "#{id}: Google Play has no #{codes[:play]} listing" if config.android? && p.empty? && block_given?
        if a["description"] && p["description"] && a["description"].strip != p["description"].strip && block_given?
          yield "#{id}: the stores have different descriptions; store.md keeps both (`## description` and `## android_description`)"
        end
        if a["name"] && p["name"] && a["name"].strip != p["name"].strip && block_given?
          yield "#{id}: the stores have different names (#{a['name']} / #{p['name']}); store.md keeps both (`## name` and `## android_name`)"
        end
        fields = p.slice(*PLAY_FIELDS).merge(a.slice(*APPLE_FIELDS)) { |_k, play_value, apple_value| apple_value || play_value }
        # What differs between the stores stays different: the Play text goes under its own android_ section.
        %w[name description].each do |k|
          next unless a[k].to_s.strip != "" && p[k].to_s.strip != "" && a[k].strip != p[k].strip
          fields["android_#{k}"] = p[k]
        end
        captions = existing&.locales&.dig(id, "captions") || {}
        section(id, fields, config.screenshots.to_h { |s| [s, captions[s] || "Caption for #{s}"] })
      end
      extra = (apple_locales.keys - config.locales.values.map { |c| c[:apple] }) + (play_locales.keys - config.locales.values.map { |c| c[:play] })
      if extra.any? && block_given?
        yield "the stores also have #{extra.uniq.sort.join(', ')}; add them under `locales` in storeautopilot.yml and import again"
      end
      yaml = YAML.dump(front.compact.reject { |_, v| v.to_s.strip.empty? }).delete_prefix("---\n")
      "---\n#{yaml}---\n#{sections.join("\n")}"
    end

    def self.section(id, fields, captions)
      out = +"# #{id}\n"
      Listing::FIELDS.each do |field|
        next if field == "captions"
        store_specific = Listing::STORE_PREFIXES.values.any? { |pre| field.start_with?(pre) }
        next if store_specific && fields[field].to_s.strip.empty?
        out << "## #{field}\n"
        out << "#{fields[field].to_s.strip.gsub(/^#/, ' #')}\n" unless fields[field].to_s.strip.empty?
      end
      out << "## captions\n"
      captions.each { |shot, caption| out << "- #{shot}: #{caption}\n" }
      out
    end

    private

    def fetch(platform)
      return nil unless @config.platforms.include?(platform)
      if (problem = @secrets.problems([platform]).first)
        UI.warn("#{platform == :ios ? 'App Store' : 'Google Play'} skipped: #{problem.first}")
        return nil
      end
      UI.step("Reading the #{platform == :ios ? 'App Store' : 'Google Play'} listing")
      result = @fastlane.lane(platform, :listing, yield, quiet: true, retries: @config.feature?(:retries) ? 1 : 0)
      if result["error"] || result["app"] == false
        UI.warn(result["error"] || "no app with bundle ID #{@config.ios[:bundle_id]} in App Store Connect")
        return nil
      end
      UI.ok("#{(result['locales'] || {}).size} language(s)")
      result
    end

    def existing_listing
      File.exist?(@config.listing_path) ? Listing.load(@config.listing_path) : nil
    rescue Error
      nil
    end

    def check(path)
      UI.step("Wrote #{File.basename(path)}")
      Listing.parse(File.read(path)).validate!(@config)
      UI.ok("passes the store checks")
    rescue Error => e
      UI.warn("fix before releasing:\n#{e.message.lines.drop(1).join}")
    end
  end
end
