require "test_helper"

class RunnerInstallTest < Minitest::Test
  def test_refuses_public_repo
    shell = FakeShell.new("repo view" => JSON.generate(nameWithOwner: "me/app", isPrivate: false))
    Dir.mktmpdir do |home|
      err = assert_raises(StoreAutopilot::Error) { StoreAutopilot::RunnerInstall.new(root: home, shell: shell, home: home).run }
      assert_includes err.message, "public"
      assert_empty shell.runs
    end
  end

  def test_refuses_download_with_wrong_checksum
    release = JSON.generate(body: "<!-- BEGIN SHA osx-arm64 -->#{'a' * 64}<!-- END SHA osx-arm64 -->",
                            assets: [{ name: "actions-runner-osx-arm64-2.330.0.tar.gz", browser_download_url: "https://x/r.tgz" }])
    shell = FakeShell.new("repo view" => JSON.generate(nameWithOwner: "me/app", isPrivate: true), "releases/latest" => release)
    shell.on_run { |cmd, _| File.write(cmd[cmd.index("-o") + 1], "not the runner") if cmd.first == "curl" }
    Dir.mktmpdir do |home|
      err = assert_raises(StoreAutopilot::Error) { StoreAutopilot::RunnerInstall.new(root: home, shell: shell, home: home, arch: "arm64").run }
      assert_includes err.message, "checksum"
      refute(shell.runs.any? { |c| c.first == "./config.sh" })
    end
  end

  def test_already_registered_just_restarts_service
    shell = FakeShell.new("repo view" => JSON.generate(nameWithOwner: "me/app", isPrivate: true))
    Dir.mktmpdir do |home|
      dir = File.join(home, ".storeautopilot", "runners", "me-app")
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, ".runner"), "{}")
      StoreAutopilot::RunnerInstall.new(root: home, shell: shell, home: home).run
      assert_equal [["./svc.sh", "start"]], shell.runs
    end
  end

  # svc.sh writes SessionCreate=true, which gives the job its own security session where the login keychain is
  # locked: codesign then fails with errSecInternalComponent. The installer turns it off before starting.
  def test_service_shares_login_keychain_session
    shell = FakeShell.new("repo view" => JSON.generate(nameWithOwner: "me/app", isPrivate: true))
    Dir.mktmpdir do |home|
      dir = File.join(home, ".storeautopilot", "runners", "me-app")
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, ".runner"), "{}")
      File.write(File.join(dir, ".service"), "/L/actions.runner.me-app.plist\n")
      StoreAutopilot::RunnerInstall.new(root: home, shell: shell, home: home).run
      assert_equal [["plutil", "-replace", "SessionCreate", "-bool", "false", "/L/actions.runner.me-app.plist"],
                    ["./svc.sh", "start"]], shell.runs
    end
  end
end
