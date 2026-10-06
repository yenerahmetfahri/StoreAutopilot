require "json"
require "digest"
require "socket"
require "rbconfig"
require "fileutils"

module StoreAutopilot
  # Registers this Mac as a self-hosted runner for one private repo and runs it as a launchd service.
  class RunnerInstall
    LABEL = "storeautopilot"

    def initialize(root:, shell:, home: Dir.home, arch: RbConfig::CONFIG["host_cpu"])
      @root = root
      @shell = shell
      @home = home
      @arch = arch.include?("arm") ? "arm64" : "x64"
    end

    def run
      repo = JSON.parse(@shell.capture("gh", "repo", "view", "--json", "nameWithOwner,isPrivate", chdir: @root))
      name = repo["nameWithOwner"]
      unless repo["isPrivate"]
        raise Error.new("#{name} is public; a self-hosted runner would let anyone run code on this Mac.",
                        hint: "Make the repository private first.")
      end
      dir = File.join(@home, ".storeautopilot", "runners", name.tr("/", "-"))
      if File.file?(File.join(dir, ".runner"))
        share_login_keychain(dir)
        @shell.run("./svc.sh", "start", chdir: dir)
        return UI.ok("runner for #{name} already registered; service started")
      end
      FileUtils.mkdir_p(dir)
      download(dir)
      UI.step("Registering runner for #{name}")
      token = @shell.capture("gh", "api", "-X", "POST", "repos/#{name}/actions/runners/registration-token", "--jq", ".token").strip
      @shell.run("./config.sh", "--unattended", "--url", "https://github.com/#{name}", "--token", token,
                 "--labels", LABEL, "--name", "#{Socket.gethostname.split('.').first}-#{LABEL}", "--replace", chdir: dir)
      # The service gets this PATH, so the workflow finds storeautopilot, fastlane and flutter.
      File.write(File.join(dir, ".path"), [File.join(ROOT, "bin"), ENV["PATH"]].join(File::PATH_SEPARATOR))
      @shell.run("./svc.sh", "install", chdir: dir)
      share_login_keychain(dir)
      @shell.run("./svc.sh", "start", chdir: dir)
      UI.ok("runner installed in #{dir} and started")
    end

    private

    # svc.sh sets SessionCreate=true: the job then gets its own security session, where the login keychain is locked
    # and codesign fails with errSecInternalComponent. Without it the job shares the logged-in user's session.
    def share_login_keychain(dir)
      service = File.join(dir, ".service")
      return unless File.file?(service)
      @shell.run("plutil", "-replace", "SessionCreate", "-bool", "false", File.read(service).strip)
    end

    def download(dir)
      UI.step("Downloading the GitHub Actions runner")
      release = JSON.parse(@shell.capture("gh", "api", "repos/actions/runner/releases/latest"))
      asset = release["assets"].find { |a| a["name"] =~ /\Aactions-runner-osx-#{@arch}-[\d.]+\.tar\.gz\z/ }
      expected = release["body"].to_s[/<!-- BEGIN SHA osx-#{@arch} -->(\h{64})<!-- END SHA osx-#{@arch} -->/, 1]
      raise Error.new("Could not find the osx-#{@arch} runner and its checksum in the latest release.") unless asset && expected
      tarball = File.join(dir, "runner.tar.gz")
      @shell.run("curl", "-fsSL", "-o", tarball, asset["browser_download_url"])
      actual = Digest::SHA256.file(tarball).hexdigest
      unless actual == expected
        FileUtils.rm_f(tarball)
        raise Error.new("Runner download checksum mismatch; refusing to install.", hint: "Try again later.")
      end
      @shell.run("tar", "xzf", tarball, "-C", dir)
      FileUtils.rm_f(tarball)
    end
  end
end
