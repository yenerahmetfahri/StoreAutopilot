require "test_helper"

class ShotInputsTest < Minitest::Test
  include Fixtures

  def git(dir, *args) = system("git", "-C", dir, *args, out: File::NULL, err: File::NULL)

  def with_repo
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "pubspec.yaml"), "name: demo_app\nversion: 1.0.0+1\n")
      config = StoreAutopilot::Config.load(make_app(dir, yml: Fixtures::VALID_YML.sub("flutter_project: app", "flutter_project: .")))
      FileUtils.mkdir_p(File.join(dir, "lib"))
      File.write(File.join(dir, "lib", "main.dart"), "void main() {}")
      File.write(File.join(dir, ".gitignore"), "build/\n")
      git(dir, "init", "-q")
      git(dir, "add", "-A")
      yield dir, StoreAutopilot::ShotInputs.new(config: config, shell: StoreAutopilot::Shell.new)
    end
  end

  def test_only_app_changes_count
    with_repo do |dir, inputs|
      before = inputs.digest(:ios)
      refute_nil before
      File.write(File.join(dir, "store.md"), "new text")
      File.write(File.join(dir, "pubspec.yaml"), "name: demo_app\nversion: 1.0.1+2\n")
      FileUtils.mkdir_p(File.join(dir, "build"))
      File.write(File.join(dir, "build", "out.bin"), "ignored")
      File.write(File.join(dir, "README.md"), "docs")
      assert_equal before, inputs.digest(:ios)
      File.write(File.join(dir, "lib", "main.dart"), "void main() { run(); }") # uncommitted edits count
      refute_equal before, inputs.digest(:ios)
    end
  end

  def test_each_device_has_its_own_fingerprint
    with_repo { |_dir, inputs| refute_equal inputs.digest(:ios), inputs.digest(:ipad) }
  end

  def test_no_git_repo_means_no_fingerprint
    Dir.mktmpdir do |dir|
      config = StoreAutopilot::Config.load(make_app(dir))
      assert_nil StoreAutopilot::ShotInputs.new(config: config, shell: StoreAutopilot::Shell.new).digest(:ios)
    end
  end
end
