require "test_helper"

class CommandsTest < Minitest::Test
  include Fixtures

  def test_release_dry_run_through_cli
    Dir.mktmpdir do |dir|
      path = make_app(dir)
      StoreAutopilot::UI.out = (out = StringIO.new)
      ENV["STOREAUTOPILOT_HOME"] = File.join(dir, "home")
      make_secrets(ENV["STOREAUTOPILOT_HOME"])
      # A dry run only checks that the tools exist; stand-ins keep the test independent of the machine.
      bin = File.join(dir, "bin")
      FileUtils.mkdir_p(bin)
      %w[fastlane flutter].each { |t| File.write(File.join(bin, t), "#!/bin/sh\n").then { File.chmod(0o755, File.join(bin, t)) } }
      path_before = ENV["PATH"]
      ENV["PATH"] = [bin, path_before].join(File::PATH_SEPARATOR)
      assert_equal 0, StoreAutopilot::CLI.start(["release", "--dry-run", "--config", path])
      assert_includes out.string, "would build the iOS app"
    ensure
      ENV["PATH"] = path_before if path_before
      ENV.delete("STOREAUTOPILOT_HOME")
    end
  end

  def test_rollout_needs_a_number
    StoreAutopilot::UI.out = (out = StringIO.new)
    assert_equal 1, StoreAutopilot::CLI.start(["rollout", "lots"])
    assert_includes out.string, "rollout percentage"
  end

  def test_runner_requires_install_subcommand
    StoreAutopilot::UI.out = (out = StringIO.new)
    assert_equal 1, StoreAutopilot::CLI.start(["runner"])
    assert_includes out.string, "runner install"
  end
end
