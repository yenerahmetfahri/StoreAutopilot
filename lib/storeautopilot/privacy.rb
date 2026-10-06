module StoreAutopilot
  # One data declaration (store.md front matter `privacy`) for both stores' privacy forms: Apple's App Privacy and
  # Google Play's Data safety. Neither form can be filled through an API key, so this prints what to tick in each,
  # in the stores' own words, and checks the declaration against SDKs the app is known to use.
  class Privacy
    # our id => [App Store category › type, Google Play category › type]
    TYPES = {
      "name" => ["Contact Info › Name", "Personal info › Name"],
      "email" => ["Contact Info › Email Address", "Personal info › Email address"],
      "phone" => ["Contact Info › Phone Number", "Personal info › Phone number"],
      "user_id" => ["Identifiers › User ID", "Personal info › User IDs"],
      "device_id" => ["Identifiers › Device ID", "Device or other IDs › Device or other IDs"],
      "purchases" => ["Purchases › Purchase History", "Financial info › Purchase history"],
      "product_interaction" => ["Usage Data › Product Interaction", "App activity › App interactions"],
      "advertising_data" => ["Usage Data › Advertising Data", "App activity › Other actions"],
      "crash_data" => ["Diagnostics › Crash Data", "App info and performance › Crash logs"],
      "performance_data" => ["Diagnostics › Performance Data", "App info and performance › Diagnostics"],
      "coarse_location" => ["Location › Coarse Location", "Location › Approximate location"],
      "precise_location" => ["Location › Precise Location", "Location › Precise location"],
      "photos" => ["User Content › Photos or Videos", "Photos and videos › Photos"],
      "gameplay" => ["User Content › Gameplay Content", "App activity › Other user-generated content"],
      "user_content" => ["User Content › Other User Content", "App activity › Other user-generated content"]
    }.freeze
    # our id => [App Store purpose, Google Play purpose]
    PURPOSES = {
      "app_functionality" => ["App Functionality", "App functionality"],
      "analytics" => ["Analytics", "Analytics"],
      "advertising" => ["Third-Party Advertising", "Advertising or marketing"],
      "developer_advertising" => ["Developer's Advertising or Marketing", "Advertising or marketing"],
      "personalization" => ["Product Personalization", "Personalization"],
      "account" => ["App Functionality", "Account management"],
      "fraud_prevention" => ["App Functionality", "Fraud prevention, security, and compliance"],
      "developer_communications" => ["Other Purposes", "Developer communications"]
    }.freeze
    # pubspec.lock package => data it is documented to collect, as [type, purpose]
    SDKS = {
      "google_mobile_ads" => [%w[device_id advertising], %w[product_interaction advertising], %w[performance_data analytics],
                              %w[coarse_location advertising]],
      "firebase_analytics" => [%w[device_id analytics], %w[product_interaction analytics]],
      "firebase_crashlytics" => [%w[crash_data analytics], %w[device_id analytics]],
      "sentry_flutter" => [%w[crash_data analytics], %w[performance_data analytics]],
      "purchases_flutter" => [%w[purchases app_functionality], %w[user_id app_functionality]],
      "firebase_auth" => [%w[user_id account], %w[email account]],
      "google_sign_in" => [%w[email account], %w[name account], %w[user_id account]],
      "sign_in_with_apple" => [%w[email account], %w[name account], %w[user_id account]]
    }.freeze
    FLAGS = %w[tracking encrypted_in_transit deletion_request].freeze

    attr_reader :collected

    # nil when store.md declares nothing.
    def self.from(listing)
      raw = listing.meta["privacy"]
      raw.nil? ? nil : new(raw)
    end

    def initialize(raw)
      @raw = raw.is_a?(Hash) ? raw : {}
      @problems = raw.is_a?(Hash) ? [] : ["privacy: expected settings below it"]
      @collected = Array(@raw["collected"]).map { |entry| parse_entry(entry) }.compact
      FLAGS.each { |f| @problems << "privacy.#{f}: true or false" unless [nil, true, false].include?(@raw[f]) }
    end

    def problems = @problems

    def flag(name) = @raw[name]

    # Packages from pubspec.lock whose known data collection the declaration doesn't cover: ["pkg: type (purpose)", ...]
    def sdk_gaps(packages)
      declared = collected.flat_map { |c| c[:purposes].map { |p| [c[:type], p] } }
      packages.flat_map do |pkg|
        (SDKS[pkg] || []).reject { |type, purpose| declared.include?([type, purpose]) }
                         .map { |type, purpose| "#{pkg} usually collects #{type} for #{purpose}" }
      end
    end

    # A starting declaration (YAML) from the packages the app uses.
    def self.suggestion(packages)
      by_type = packages.flat_map { |pkg| SDKS[pkg] }.group_by(&:first).transform_values { |pairs| pairs.map(&:last).uniq }
      lines = ["privacy:", "  tracking: false            # true if data links to other companies' data for ads (needs App Tracking Transparency)",
               "  encrypted_in_transit: true", "  deletion_request: true     # users can ask you to delete their data",
               "  collected:#{' []' if by_type.empty?}"]
      by_type.each do |type, purposes|
        linked = purposes.intersect?(%w[account app_functionality]) # account and purchase data belong to a person
        lines << "    - { type: #{type}, purposes: [#{purposes.join(', ')}], linked: #{linked}, shared: #{purposes.include?('advertising')} }"
      end
      lines.join("\n")
    end

    def self.packages(flutter_dir)
      lock = File.join(flutter_dir, "pubspec.lock")
      File.file?(lock) ? File.read(lock).scan(/^  (\w+):$/).flatten & SDKS.keys : []
    end

    # Lines for App Store Connect → App Privacy.
    def apple_lines
      return ["Data Collection: No, we do not collect data from this app"] if collected.empty?
      lines = ["Data Collection: Yes"]
      collected.each do |c|
        purposes = c[:purposes].map { |p| PURPOSES.fetch(p).first }.uniq.join(", ")
        lines << "#{TYPES.fetch(c[:type]).first} — purposes: #{purposes}; linked to the user: #{yes(c[:linked])}; " \
                 "used for tracking: #{yes(c[:tracking])}"
      end
      lines
    end

    # Lines for Play Console → App content → Data safety.
    def play_lines
      lines = ["Does your app collect or share any of the required user data types? #{yes(collected.any?)}"]
      return lines if collected.empty?
      lines << "Is all of the user data collected by your app encrypted in transit? #{yes(flag('encrypted_in_transit'))}"
      lines << "Do you provide a way for users to request that their data is deleted? #{yes(flag('deletion_request'))}"
      collected.group_by { |c| TYPES.fetch(c[:type]).last }.each do |label, entries|
        purposes = entries.flat_map { |c| c[:purposes].map { |p| PURPOSES.fetch(p).last } }.uniq.join(", ")
        shared = entries.any? { |c| c[:shared] }
        optional = entries.all? { |c| c[:optional] }
        lines << "#{label} — collected#{', shared' if shared}; #{optional ? 'optional' : 'required'}; purposes: #{purposes}"
      end
      lines
    end

    private

    def yes(value) = value ? "Yes" : "No"

    def parse_entry(entry)
      unless entry.is_a?(Hash) && TYPES.key?(entry["type"].to_s)
        @problems << "privacy.collected: unknown type #{entry.is_a?(Hash) ? entry['type'].inspect : entry.inspect} (#{TYPES.keys.join(', ')})"
        return nil
      end
      purposes = Array(entry["purposes"]).map(&:to_s)
      unknown = purposes - PURPOSES.keys
      @problems << "privacy.collected #{entry['type']}: unknown purpose #{unknown.join(', ')} (#{PURPOSES.keys.join(', ')})" if unknown.any?
      @problems << "privacy.collected #{entry['type']}: list at least one purpose" if purposes.empty?
      { type: entry["type"].to_s, purposes: purposes & PURPOSES.keys, linked: entry.fetch("linked", true) == true,
        tracking: entry["tracking"] == true, shared: entry["shared"] == true, optional: entry["optional"] == true }
    end
  end
end
