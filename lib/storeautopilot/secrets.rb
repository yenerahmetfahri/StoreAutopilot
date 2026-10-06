require "json"
require "fileutils"

module StoreAutopilot
  # ~/.storeautopilot/<app_id>/: keys and state. Contents are never printed.
  # Keys used by several apps (one App Store Connect key, one Play service account) can live once in
  # ~/.storeautopilot/shared/; a key in the app's own folder wins.
  class Secrets
    SHARED = "shared"

    ASC_HINT = "App Store Connect → Users and Access → Integrations → App Store Connect API: create a key " \
               "(App Manager), save it as asc_key.p8 and write asc_key.json: {\"key_id\": \"…\", \"issuer_id\": \"…\"}"
    PLAY_HINT = "Google Cloud: create a service account + JSON key, invite its email in Play Console → Users and " \
                "permissions (release + store listing rights), save the key as play.json"

    attr_reader :dir

    def initialize(app_id, home: Dir.home)
      @dir = File.join(home, ".storeautopilot", app_id)
      @shared = File.join(home, ".storeautopilot", SHARED)
    end

    attr_reader :shared

    def asc_key_path = key("asc_key.p8")
    def asc_json_path = key("asc_key.json")
    def play_json_path = key("play.json")
    def state_path = File.join(dir, "state.json")
    def demo_password_path = File.join(dir, "review_demo_password.txt")

    # The App Review demo account's password, if store.md names a demo user. [password, problem]
    def demo_password(listing)
      return [nil, nil] unless listing.review_demo_user
      return [nil, "store.md names review_demo_user, but #{demo_password_path} is missing"] unless File.file?(demo_password_path)
      password = File.read(demo_password_path).strip
      password.empty? ? [nil, "#{demo_password_path} is empty"] : [password, nil]
    end

    def ensure_dir!
      FileUtils.mkdir_p(dir)
      File.chmod(0o700, File.dirname(dir), dir)
    end

    # Tightens permissions; returns the paths it changed.
    def tighten!
      paths = [dir, @shared].select { |d| File.directory?(d) }.flat_map { |d| [d] + Dir.children(d).map { |c| File.join(d, c) } }
      paths.select { |p| loose?(p) }.each { |p| File.chmod(File.directory?(p) ? 0o700 : 0o600, p) }
    end

    # [[message, hint], ...] — empty when ready for the given platforms.
    def problems(platforms)
      return [["#{dir} does not exist", "Run `storeautopilot init`."]] unless File.directory?(dir)
      list = []
      [dir, @shared].select { |d| File.directory?(d) && loose?(d) }.each do |d|
        list << ["#{d} is readable by others", "Run `storeautopilot doctor` to fix permissions."]
      end
      if platforms.include?(:ios)
        list.concat(file_problems(asc_key_path, ASC_HINT) { |t| "not a .p8 private key" unless t.include?("BEGIN PRIVATE KEY") })
        list.concat(file_problems(asc_json_path, ASC_HINT) { |t| asc_json_problem(t) })
      end
      if platforms.include?(:android)
        list.concat(file_problems(play_json_path, PLAY_HINT) { |t| play_json_problem(t) })
      end
      list
    end

    private

    def loose?(path) = (File.stat(path).mode & 0o077) != 0

    # The app's own copy if there is one, else the shared one; the app's path when neither exists.
    def key(name)
      own = File.join(dir, name)
      shared = File.join(@shared, name)
      File.file?(own) || !File.file?(shared) ? own : shared
    end

    def file_problems(path, hint)
      unless File.file?(path)
        name = File.basename(path)
        return [["missing #{name} (in #{dir}, or #{@shared} for keys several apps use)", hint]]
      end
      list = []
      list << ["#{path} is readable by others", "Run `storeautopilot doctor` to fix permissions."] if loose?(path)
      issue = yield(File.read(path))
      list << ["#{path}: #{issue}", hint] if issue
      list
    end

    def asc_json_problem(text)
      data = JSON.parse(text)
      "needs non-empty key_id and issuer_id" if data["key_id"].to_s.empty? || data["issuer_id"].to_s.empty?
    rescue JSON::ParserError
      "not valid JSON (needs key_id and issuer_id)"
    end

    def play_json_problem(text)
      data = JSON.parse(text)
      "not a Google service account key" unless data["type"] == "service_account" && data["client_email"]
    rescue JSON::ParserError
      "not valid JSON (expected a Google service account key)"
    end
  end
end
