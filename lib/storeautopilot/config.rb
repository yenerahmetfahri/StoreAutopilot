require "yaml"

module StoreAutopilot
  # Non-secret, per-app settings from the app repo's storeautopilot.yml.
  class Config
    HEX = /\A#\h{6}\z/
    FONT = /\A[\w ,.\-]+\z/ # no quotes: the value is placed inside a <style> block

    attr_reader :root, :app_id, :flutter_dir, :locales, :screenshots, :brand, :ios, :android

    def self.load(path)
      path = File.expand_path(path)
      raise Error.new("#{path} not found.", hint: "Run `storeautopilot init` in your app repo.") unless File.file?(path)
      data = YAML.safe_load(File.read(path)) || {}
      raise Error.new("storeautopilot.yml must be a mapping of settings (key: value).") unless data.is_a?(Hash)
      new(data, root: File.dirname(path))
    rescue Psych::Exception => e
      raise Error.new("storeautopilot.yml is not valid YAML: #{e.message}")
    end

    def initialize(data, root:)
      @root = root
      problems = []
      @app_id = data["app_id"].to_s
      problems << "app_id: use lowercase letters, digits, '.', '_' or '-'" unless @app_id.match?(/\A[a-z0-9][a-z0-9._-]*\z/)
      @flutter_dir = File.expand_path(data["flutter_project"] || ".", root)
      problems << "flutter_project: no pubspec.yaml in #{@flutter_dir}" unless File.file?(File.join(@flutter_dir, "pubspec.yaml"))
      @locales = parse_locales(data["locales"], problems)
      @screenshots = Array(data["screenshots"]).map(&:to_s)
      problems << "screenshots: list at least one id" if @screenshots.empty?
      bad = @screenshots.grep_v(/\A[a-z0-9_]+\z/)
      problems << "screenshots: ids use lowercase letters, digits, '_' (#{bad.join(', ')})" if bad.any?
      @brand = parse_brand(section(data, "brand", problems) || {}, problems)
      @ios = parse_ios(section(data, "ios", problems), problems)
      @android = parse_android(section(data, "android", problems), problems)
      problems << "ios / android: configure at least one" unless @ios || @android
      return if problems.empty?
      raise Error.new("storeautopilot.yml has problems:\n#{problems.map { |p| "    - #{p}" }.join("\n")}")
    end

    def self.percent?(value) = value.is_a?(Numeric) && value.positive? && value <= 100

    def ios? = !@ios.nil?

    # iPad screenshots are needed when the app runs on iPad: `ios.ipad` if set, else the Xcode project's device family.
    def ipad?
      return false unless ios?
      return @ios[:ipad] unless @ios[:ipad].nil?
      pbx = File.join(flutter_dir, "ios", "Runner.xcodeproj", "project.pbxproj")
      File.file?(pbx) && File.read(pbx).scan(/TARGETED_DEVICE_FAMILY = "?([\d,]+)"?;/).flatten.any? { |f| f.split(",").include?("2") }
    end

    def android? = !@android.nil?
    def platforms = [(:ios if ios?), (:android if android?)].compact
    def listing_path = File.join(root, "store.md")

    # The app's own template if present, else the built-in one.
    def template_path(name)
      own = File.join(root, "storeautopilot", name)
      File.file?(own) ? own : File.join(TEMPLATES, "app", "storeautopilot", name)
    end

    # Play's Data safety form as exported from Play Console, kept in the app repo; uploaded whenever it changes.
    def data_safety_csv
      path = File.join(root, "storeautopilot", "data_safety.csv")
      File.file?(path) ? path : nil
    end

    def info_plist = File.join(flutter_dir, "ios", "Runner", "Info.plist")

    # Whether Info.plist answers Apple's export compliance question (ITSAppUsesNonExemptEncryption).
    def encryption_declared? = File.file?(info_plist) && File.read(info_plist).include?("ITSAppUsesNonExemptEncryption")

    def version_name
      version = File.read(File.join(flutter_dir, "pubspec.yaml"))[/^version:\s*(\S+)/, 1]
      raise Error.new("pubspec.yaml has no version.", hint: "Add e.g. `version: 1.0.0+1`.") unless version
      version.split("+").first
    end

    private

    # A nested mapping, or nil when absent; anything else is reported.
    def section(data, key, problems)
      value = data[key]
      return value if value.nil? || value.is_a?(Hash)
      problems << "#{key}: expected settings below it (key: value), got #{value.inspect}"
      nil
    end

    def parse_locales(raw, problems)
      unless raw.is_a?(Hash) && raw.any?
        problems << "locales: add at least one, e.g. `en: { apple: en-US, play: en-US }`"
        return {}
      end
      raw.to_h do |id, codes|
        codes = {} unless codes.is_a?(Hash)
        problems << "locales.#{id}: needs `apple` and `play` codes" unless codes["apple"] && codes["play"]
        [id.to_s, { apple: codes["apple"].to_s, play: codes["play"].to_s }]
      end
    end

    def parse_brand(raw, problems)
      brand = {
        background: raw["background"] || "#111827",
        text: raw["text"] || "#FFFFFF",
        accent: raw["accent"] || "#F59E0B",
        font: raw["font"] || "-apple-system, Helvetica Neue, Arial, sans-serif"
      }
      %i[background text accent].each { |k| problems << "brand.#{k}: use a #RRGGBB color" unless brand[k].to_s.match?(HEX) }
      problems << "brand.font: letters, digits, spaces, commas, '-' and '.' only" unless brand[:font].to_s.match?(FONT)
      brand
    end

    def parse_ios(raw, problems)
      return nil if raw.nil?
      id = raw["bundle_id"].to_s
      problems << "ios.bundle_id is required" if id.empty?
      problems << "ios.ipad: true or false (leave it out to follow the Xcode project)" unless [nil, true, false].include?(raw["ipad"])
      %w[phased_release testflight_notes uses_encryption].each do |key|
        problems << "ios.#{key}: true or false" unless [nil, true, false].include?(raw[key])
      end
      { bundle_id: id, ipad: raw["ipad"], phased_release: raw["phased_release"] == true,
        testflight_notes: raw["testflight_notes"] == true, uses_encryption: raw["uses_encryption"] }
    end

    def parse_android(raw, problems)
      return nil if raw.nil?
      package = raw["package"].to_s
      problems << "android.package is required" if package.empty?
      status = raw["release_status"] || "completed"
      problems << "android.release_status: completed or draft" unless %w[completed draft].include?(status)
      keystore = raw["keystore_properties"] && File.expand_path(raw["keystore_properties"])
      rollout = raw.fetch("rollout", 100)
      problems << "android.rollout: a percentage above 0 and up to 100" unless Config.percent?(rollout)
      { package: package, track: raw["track"] || "internal", release_status: status,
        emulator: raw["emulator"], keystore_properties: keystore, rollout: rollout }
    end
  end
end
