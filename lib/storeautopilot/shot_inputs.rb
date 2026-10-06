require "digest"

module StoreAutopilot
  # Fingerprint of everything that can change how the app looks in its screenshots: the Flutter project's files as git
  # sees them (tracked and untracked, ignored ones left out), the screenshot ids and locales, and the device. Store
  # text, templates and the version line in pubspec.yaml don't count, so a text-only or version-only release reuses
  # the last screenshots.
  class ShotInputs
    IGNORED = %r{\A(test/|\.github/|fastlane/|storeautopilot/)|\A(storeautopilot\.yml|store\.md)\z|\.md\z}

    def initialize(config:, shell:)
      @config = config
      @shell = shell
    end

    # nil when it can't be worked out (not a git repo); the caller then always captures.
    def digest(target)
      files = @shell.capture("git", "ls-files", "-z", "--cached", "--others", "--exclude-standard",
                             chdir: @config.flutter_dir, allow_failure: true).split("\0").uniq.sort
      files.reject! { |f| f.match?(IGNORED) }
      return nil if files.empty?
      sha = Digest::SHA256.new
      sha << [target, @config.screenshots, @config.locales.keys].inspect << "\0"
      files.each do |rel|
        path = File.join(@config.flutter_dir, rel)
        next unless File.file?(path)
        content = File.binread(path)
        content = content.gsub(/^version:.*$/, "") if rel == "pubspec.yaml"
        sha << rel << "\0" << content << "\0"
      end
      sha.hexdigest
    end
  end
end
