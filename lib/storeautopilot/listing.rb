require "yaml"
require "json"
require "fileutils"

module StoreAutopilot
  # store.md: YAML front matter + `# <locale>` sections with `## <field>` subsections.
  # Field bodies are plain text; don't start lines with '#' inside them.
  class Listing
    TEXT_FIELDS = %w[name subtitle keywords promotional_text description short_description release_notes].freeze
    # `## ios_description` / `## android_description` replace `## description` in that store only.
    STORE_PREFIXES = { ios: "ios_", android: "android_" }.freeze
    FIELDS = (TEXT_FIELDS + ["captions"] + TEXT_FIELDS.flat_map { |k| STORE_PREFIXES.values.map { |pre| "#{pre}#{k}" } }).freeze
    LIMITS = {
      ios: { "name" => 30, "subtitle" => 30, "keywords" => 100, "promotional_text" => 170, "description" => 4000, "release_notes" => 4000 },
      android: { "name" => 30, "short_description" => 80, "description" => 4000, "release_notes" => 500 }
    }.freeze
    REQUIRED = { ios: %w[name description keywords], android: %w[name short_description description] }.freeze
    META_REQUIRED = { ios: %w[support_url privacy_url], android: %w[privacy_url] }.freeze
    APPLE_TEXT = %w[name subtitle keywords promotional_text description release_notes].freeze
    APPLE_URLS = %w[support_url marketing_url privacy_url].freeze
    # front matter review_contact key => deliver review_information file
    REVIEW_CONTACT = { "first_name" => "first_name", "last_name" => "last_name", "phone" => "phone_number",
                       "email" => "email_address" }.freeze

    attr_reader :meta, :locales

    def self.load(path)
      raise Error.new("#{path} not found.", hint: "Run `storeautopilot init`.") unless File.file?(path)
      parse(File.read(path))
    end

    def self.parse(text)
      meta = {}
      if text.start_with?("---\n")
        front, text = text.delete_prefix("---\n").split(/^---\s*$\n?/, 2)
        meta = YAML.safe_load(front.to_s) || {}
        raise Error.new("store.md front matter must be a mapping (key: value).") unless meta.is_a?(Hash)
        text = text.to_s
      end
      locales = {}
      locale = field = nil
      text.each_line do |line|
        if line =~ /\A#\s+(\S+)\s*\z/
          locale = locales[$1] = {}
          field = nil
        elsif locale && line =~ /\A##\s+(\S+)\s*\z/
          field = $1.downcase
          raise Error.new("store.md: unknown section `## #{field}`", hint: "Known: #{FIELDS.join(', ')}") unless FIELDS.include?(field)
          locale[field] = +""
        elsif locale && field
          locale[field] << line
        end
      end
      locales.each_value do |fields|
        fields.transform_values!(&:strip)
        fields["captions"] = parse_captions(fields["captions"]) if fields.key?("captions")
      end
      new(meta, locales)
    rescue Psych::Exception => e
      raise Error.new("store.md front matter is not valid YAML: #{e.message}")
    end

    def self.parse_captions(text)
      text.lines.filter_map { |l| [$1, $2] if l =~ /\A\s*-\s*([a-z0-9_]+)\s*:\s*(.+?)\s*\z/ }.to_h
    end

    def initialize(meta, locales)
      @meta = meta
      @locales = locales
    end

    # The text of one language as one store shows it: a store-specific section (`ios_description`) wins over the shared one.
    def fields_for(id, platform)
      fields = locales[id] || {}
      prefix = STORE_PREFIXES.fetch(platform)
      TEXT_FIELDS.to_h do |k|
        own = fields["#{prefix}#{k}"].to_s
        [k, own.empty? ? fields[k] : own]
      end.merge("captions" => fields["captions"]).compact
    end

    def validate!(config)
      problems = []
      config.platforms.each do |p|
        META_REQUIRED[p].each { |k| problems << "front matter: `#{k}` is required for #{p}" if meta[k].to_s.strip.empty? }
      end
      problems.concat(review_problems) if config.ios?
      problems.concat(Privacy.from(self)&.problems || [])
      config.locales.each_key do |id|
        next problems << "missing `# #{id}` section" unless locales[id]
        config.platforms.each do |p|
          fields = fields_for(id, p)
          REQUIRED[p].each { |k| problems << "#{id}/#{k}: required for #{p}" if fields[k].to_s.empty? }
          LIMITS[p].each do |k, max|
            len = fields[k].to_s.length
            problems << "#{id}/#{k}: #{len} characters, #{p} allows #{max}" if len > max
          end
        end
        captions = locales[id]["captions"] || {}
        config.screenshots.each { |s| problems << "#{id}/captions: no caption for `#{s}`" unless captions[s] }
      end
      return self if problems.empty?
      raise Error.new("store.md has problems:\n#{problems.uniq.map { |p| "    - #{p}" }.join("\n")}")
    end

    CAPTION_COMFORT = 45 # longer captions wrap to three lines or more on the store images

    # Suggestions that don't block a release: wasted keyword characters, words the App Store already indexes from the
    # name and subtitle, captions too long for the image, missing release notes.
    def advice(config)
      list = APPLE_URLS.select { |k| meta[k].to_s.include?("//example.com") }
                       .map { |k| "#{k} is still the example address from `init`; App Review opens it" }
      config.locales.each_key do |id|
        fields = fields_for(id, :ios)
        if config.ios?
          list.concat(keyword_advice(id, fields))
          words = ->(text) { text.to_s.downcase.scan(/[[:alnum:]]+/) }
          repeated = words.(fields["subtitle"]) & words.(fields["name"])
          list << "#{id}/subtitle repeats #{repeated.join(', ')} from the name; other words reach more searches" if repeated.any?
        end
        list << "#{id}/release_notes is empty; the App Store requires it for every update" if config.ios? && fields["release_notes"].to_s.empty?
        (locales[id] || {}).fetch("captions", {}).each do |shot, caption|
          next if caption.length <= CAPTION_COMFORT
          list << "#{id}/captions/#{shot}: #{caption.length} characters may wrap to three lines; check `storeautopilot shots`"
        end
      end
      list
    end

    def keyword_advice(id, fields)
      raw = fields["keywords"].to_s
      return [] if raw.empty?
      list = []
      spaces = raw.scan(/,\s+|\s+,/).sum { |m| m.count(" ") }
      list << "#{id}/keywords: remove the #{spaces} space(s) around commas; they count against the 100 characters" if spaces.positive?
      keywords = raw.split(",").map { |k| k.strip.downcase }.reject(&:empty?)
      dupes = keywords.tally.select { |_, n| n > 1 }.keys
      list << "#{id}/keywords: #{dupes.join(', ')} listed twice" if dupes.any?
      indexed = (fields["name"].to_s + " " + fields["subtitle"].to_s).downcase.scan(/[[:alnum:]]+/)
      wasted = keywords & indexed
      list << "#{id}/keywords: #{wasted.join(', ')} already in the name or subtitle, which the App Store searches anyway" if wasted.any?
      free = 100 - keywords.join(",").length
      list << "#{id}/keywords: #{free} of 100 characters unused" if free >= 20
      list
    end

    # App Review contact: Apple calls this number or writes to this address if something blocks the review.
    def review_problems
      list = []
      unless [nil, true, false].include?(meta["third_party_content"])
        list << "front matter: third_party_content is true or false (does the app show content it doesn't own?)"
      end
      contact = meta["review_contact"]
      return list if contact.nil?
      return list << "front matter: review_contact needs first_name, last_name, phone, email below it" unless contact.is_a?(Hash)
      list += (contact.keys - REVIEW_CONTACT.keys).map { |k| "front matter: review_contact.#{k} is not known (#{REVIEW_CONTACT.keys.join(', ')})" }
      list << "front matter: review_contact.email is not an email address" if contact["email"] && !contact["email"].to_s.match?(/\A[^@\s]+@[^@\s]+\.[^@\s]+\z/)
      if contact["phone"] && !contact["phone"].to_s.match?(/\A\+[\d ()-]{6,}\z/)
        list << "front matter: review_contact.phone needs the country code, e.g. \"+1 555 010 0100\""
      end
      list
    end

    # store.md third_party_content (true/false) as App Store Connect's content rights answer, or nil if not given.
    def content_rights
      case meta["third_party_content"]
      when false then "DOES_NOT_USE_THIRD_PARTY_CONTENT"
      when true then "USES_THIRD_PARTY_CONTENT"
      end
    end

    def review_demo_user = meta["review_demo_user"].to_s.strip.then { |u| u.empty? ? nil : u }

    # fastlane deliver metadata folder. demo_password comes from the secret folder, never from store.md.
    def write_apple(dir, config, demo_password: nil)
      put(dir, "copyright.txt", meta["copyright"])
      put(dir, "primary_category.txt", meta["apple_category"])
      # App Review notes (front matter `review_notes`); deliver only sends the fields present, so the contact details
      # entered in App Store Connect stay.
      review = File.join(dir, "review_information")
      put(review, "notes.txt", meta["review_notes"])
      (meta["review_contact"].is_a?(Hash) ? meta["review_contact"] : {}).each do |key, value|
        put(review, "#{REVIEW_CONTACT.fetch(key)}.txt", value) if REVIEW_CONTACT.key?(key)
      end
      if review_demo_user && demo_password
        put(review, "demo_user.txt", review_demo_user)
        put(review, "demo_password.txt", demo_password)
        File.chmod(0o600, File.join(review, "demo_password.txt"))
      end
      config.locales.each do |id, codes|
        fields = fields_for(id, :ios)
        ldir = File.join(dir, codes[:apple])
        APPLE_TEXT.each { |k| put(ldir, "#{k}.txt", fields[k]) }
        APPLE_URLS.each { |k| put(ldir, "#{k}.txt", meta[k]) }
      end
      dir
    end

    # fastlane supply metadata folder (images are added by Images).
    def write_play(dir, config, version_code:)
      config.locales.each do |id, codes|
        fields = fields_for(id, :android)
        ldir = File.join(dir, codes[:play])
        put(ldir, "title.txt", fields["name"])
        put(ldir, "short_description.txt", fields["short_description"])
        put(ldir, "full_description.txt", fields["description"])
        put(File.join(ldir, "changelogs"), "#{version_code}.txt", fields["release_notes"]) if version_code
      end
      dir
    end

    # Apple locale code → release notes, for TestFlight's "What to Test".
    def testflight_notes(config)
      config.locales.to_h { |id, codes| [codes[:apple], fields_for(id, :ios)["release_notes"].to_s] }.reject { |_, t| t.empty? }
    end

    # deliver's app_rating_config_path JSON, from front matter `age_rating`.
    def write_age_rating(path)
      return nil unless meta["age_rating"].is_a?(Hash)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.pretty_generate(meta["age_rating"]))
      path
    end

    private

    def put(dir, file, value)
      return if value.to_s.strip.empty?
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, file), "#{value.to_s.strip}\n")
    end
  end
end
