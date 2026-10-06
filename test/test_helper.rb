require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "stringio"
require "json"
require "storeautopilot"

StoreAutopilot::UI.out = StringIO.new
StoreAutopilot::UI.notifications = false
ENV["STOREAUTOPILOT_LOG_DIR"] = Dir.mktmpdir("storeautopilot-logs")
Minitest.after_run { FileUtils.rm_rf(ENV["STOREAUTOPILOT_LOG_DIR"]) }

class FakeShell
  # jobs: "ios submit" => the job JSON that fastlane lane received
  attr_reader :runs, :captures, :jobs

  DF_PLENTY = "Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/disk1 500000000 1 104857600 1% /\n"

  # outputs: command substring => stdout (or a proc). Free disk space is plentiful unless a test says otherwise.
  def initialize(outputs = {})
    @outputs = { "df -Pk" => DF_PLENTY, "rev-parse" => "", "status --porcelain" => "", "xcodebuild -version" => "Xcode 27.0\n",
                 "--version --machine" => "{}" }.merge(outputs)
    @runs = []
    @captures = []
    @jobs = {}
  end

  def on_run(&block) = @on_run = block

  def run(*cmd, chdir: nil, env: {})
    @runs << cmd
    @jobs[cmd[1..2].join(" ")] = JSON.parse(File.read(env["STOREAUTOPILOT_JOB"])) if env["STOREAUTOPILOT_JOB"]
    @on_run&.call(cmd, env)
    true
  end

  def capture(*cmd, chdir: nil, env: {}, allow_failure: false, timeout: nil)
    @captures << cmd
    @jobs[cmd[1..2].join(" ")] = JSON.parse(File.read(env["STOREAUTOPILOT_JOB"])) if env["STOREAUTOPILOT_JOB"]
    line = cmd.join(" ")
    key = @outputs.keys.find { |k| line.include?(k) }
    raise "unexpected capture: #{line}" unless key
    out = @outputs[key]
    return out unless out.respond_to?(:call)
    out.arity == 2 ? out.call(cmd, env) : out.call(cmd)
  end

  def spawn_bg(*cmd)
    @runs << cmd
    4242
  end

  def available?(_name) = true
end

module Fixtures
  VALID_YML = <<~YML
    app_id: demo-app
    flutter_project: app
    locales:
      en: { apple: en-US, play: en-US }
    screenshots: [01_home, 02_play]
    brand:
      background: "#1E3A5F"
      text: "#FFFFFF"
      accent: "#D4AF37"
    ios:
      bundle_id: com.example.demo
    android:
      package: com.example.demo
  YML

  VALID_MD = <<~MD
    ---
    support_url: https://demo.example.org/support
    privacy_url: https://demo.example.org/privacy
    copyright: 2026 Example
    ---
    # en
    ## name
    Demo App
    ## subtitle
    A tiny demo
    ## keywords
    demo,example
    ## description
    The demo app description.
    ## short_description
    A short one.
    ## release_notes
    Bug fixes.
    ## captions
    - 01_home: Your home screen
    - 02_play: Play anywhere
  MD

  # Creates an app repo in dir; returns the storeautopilot.yml path.
  def make_app(dir, yml: VALID_YML, store_md: VALID_MD)
    FileUtils.mkdir_p(File.join(dir, "app"))
    File.write(File.join(dir, "app", "pubspec.yaml"), "name: demo_app\nversion: 1.2.3+4\n")
    File.write(File.join(dir, "storeautopilot.yml"), yml)
    File.write(File.join(dir, "store.md"), store_md)
    File.join(dir, "storeautopilot.yml")
  end

  # Creates a complete, correctly-permissioned secret dir for demo-app.
  def make_secrets(home, app_id: "demo-app")
    dir = File.join(home, ".storeautopilot", app_id)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "asc_key.p8"), "-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----\n")
    File.write(File.join(dir, "asc_key.json"), JSON.generate(key_id: "KEY123", issuer_id: "ISSUER"))
    File.write(File.join(dir, "play.json"), JSON.generate(type: "service_account", client_email: "x@y.iam.gserviceaccount.com"))
    Dir.children(dir).each { |f| File.chmod(0o600, File.join(dir, f)) }
    File.chmod(0o700, dir)
    dir
  end
end
