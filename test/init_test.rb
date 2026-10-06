require "test_helper"

class InitTest < Minitest::Test
  def make_flutter_repo(dir)
    FileUtils.mkdir_p(File.join(dir, "app/ios/Runner.xcodeproj"))
    FileUtils.mkdir_p(File.join(dir, "app/android/app"))
    File.write(File.join(dir, "app/pubspec.yaml"), "name: word_game\nversion: 1.0.0+1\ndev_dependencies:\n  flutter_test:\n    sdk: flutter\n")
    File.write(File.join(dir, "app/ios/Runner.xcodeproj/project.pbxproj"),
               "PRODUCT_BUNDLE_IDENTIFIER = com.acme.wordgame.RunnerTests;\nPRODUCT_BUNDLE_IDENTIFIER = com.acme.wordgame;\n")
    File.write(File.join(dir, "app/android/app/build.gradle.kts"), "android {\n  defaultConfig {\n    applicationId = \"com.acme.wordgame\"\n  }\n}\n")
    File.write(File.join(dir, ".gitignore"), "build/\n")
  end

  def test_scaffolds_valid_files_and_keeps_existing_ones
    Dir.mktmpdir do |dir|
      home = File.join(dir, "home")
      make_flutter_repo(dir)
      FileUtils.mkdir_p(File.join(dir, "storeautopilot"))
      File.write(File.join(dir, "storeautopilot/frame.html"), "mine")
      shell = FakeShell.new
      StoreAutopilot::Init.new(dir: dir, shell: shell, home: home).run

      config = StoreAutopilot::Config.load(File.join(dir, "storeautopilot.yml"))
      assert_equal "word-game", config.app_id
      assert_equal "com.acme.wordgame", config.ios[:bundle_id]
      assert_equal "com.acme.wordgame", config.android[:package]
      assert StoreAutopilot::Listing.load(File.join(dir, "store.md")).validate!(config)
      assert_equal "mine", File.read(File.join(dir, "storeautopilot/frame.html"))
      assert File.file?(File.join(dir, "app", StoreAutopilot::Screenshots::TEST))
      assert File.file?(File.join(dir, "app", StoreAutopilot::Screenshots::DRIVER))
      workflow = File.read(File.join(dir, ".github/workflows/store.yml"))
      assert_includes workflow, "branches: [release]"
      # The scheduled run only watches; it must never release or submit.
      assert_includes workflow, "if: github.event_name == 'schedule'"
      assert_includes workflow, "if: github.event_name == 'push' || (github.event_name == 'workflow_dispatch' && !inputs.submit_for_review)"
      refute_includes workflow, "pull_request"
      assert_includes File.read(File.join(dir, ".gitignore")), "*.p8"
      assert_equal 0o700, File.stat(File.join(home, ".storeautopilot", "word-game")).mode & 0o777
      assert(shell.runs.any? { |c| c.first(3) == %w[flutter pub add] })
    end
  end

  def test_questions_fill_in_the_files
    Dir.mktmpdir do |dir|
      make_flutter_repo(dir)
      answers = ["Word Game Pro", "en, de, tr", "https://acme.dev/help", "https://acme.dev/privacy", "8", "n", "n", "#0F766E"]
      prompt = StoreAutopilot::Prompt.new(input: StringIO.new(answers.join("\n") + "\n"))
      StoreAutopilot::Init.new(dir: dir, shell: FakeShell.new, home: File.join(dir, "home"), prompt: prompt).run
      config = StoreAutopilot::Config.load(File.join(dir, "storeautopilot.yml"))
      assert_equal({ "en" => { apple: "en-US", play: "en-US" }, "de" => { apple: "de-DE", play: "de-DE" },
                     "tr" => { apple: "tr", play: "tr-TR" } }, config.locales)
      assert_equal "#0F766E", config.brand[:background]
      assert_equal false, config.ios[:uses_encryption]
      listing = StoreAutopilot::Listing.load(File.join(dir, "store.md")).validate!(config)
      assert_equal "https://acme.dev/help", listing.meta["support_url"]
      assert_equal "GAMES", listing.meta["apple_category"]
      assert_equal "DOES_NOT_USE_THIRD_PARTY_CONTENT", listing.content_rights
      assert_equal "Word Game Pro", listing.locales["tr"]["name"]
      assert_empty listing.advice(config).grep(/example address/)
    end
  end

  def test_without_questions_the_example_urls_are_flagged
    Dir.mktmpdir do |dir|
      make_flutter_repo(dir)
      StoreAutopilot::Init.new(dir: dir, shell: FakeShell.new, home: File.join(dir, "home")).run
      config = StoreAutopilot::Config.load(File.join(dir, "storeautopilot.yml"))
      advice = StoreAutopilot::Listing.load(File.join(dir, "store.md")).advice(config)
      assert_includes advice, "support_url is still the example address from `init`; App Review opens it"
    end
  end

  def test_running_twice_does_not_duplicate_gitignore_block
    Dir.mktmpdir do |dir|
      make_flutter_repo(dir)
      2.times { StoreAutopilot::Init.new(dir: dir, shell: FakeShell.new, home: File.join(dir, "home")).run }
      assert_equal 1, File.read(File.join(dir, ".gitignore")).scan("# StoreAutopilot").size
    end
  end

  def test_no_flutter_project_is_an_error
    Dir.mktmpdir do |dir|
      err = assert_raises(StoreAutopilot::Error) { StoreAutopilot::Init.new(dir: dir, shell: FakeShell.new, home: dir).run }
      assert_includes err.message, "pubspec.yaml"
    end
  end
end

class InitMonorepoTest < Minitest::Test
  def flutter_app(root, folder, name)
    dir = File.join(root, folder)
    FileUtils.mkdir_p(File.join(dir, "ios/Runner.xcodeproj"))
    File.write(File.join(dir, "pubspec.yaml"), "name: #{name}\nversion: 1.0.0+1\ndev_dependencies:\n  integration_test:\n  flutter_driver:\n")
    File.write(File.join(dir, "ios/Runner.xcodeproj/project.pbxproj"), "PRODUCT_BUNDLE_IDENTIFIER = com.acme.#{name};\n")
  end

  def repo(dir)
    FileUtils.mkdir_p(File.join(dir, ".git"))
    flutter_app(dir, "apps/game", "game")
    flutter_app(dir, "apps/quiz", "quiz")
  end

  def init(dir, **kw) = StoreAutopilot::Init.new(dir: dir, shell: FakeShell.new, home: File.join(dir, "home"), **kw).run

  def test_several_apps_need_a_choice
    Dir.mktmpdir do |dir|
      repo(dir)
      err = assert_raises(StoreAutopilot::Error) { init(dir) }
      assert_includes err.message, "apps/game, apps/quiz"
      assert_includes err.hint, "--app"
    end
  end

  def test_each_app_gets_its_own_files_workflow_and_branch
    Dir.mktmpdir do |dir|
      repo(dir)
      init(dir, app: "apps/game")
      init(dir, app: "apps/quiz/")
      %w[game quiz].each do |name|
        config = StoreAutopilot::Config.load(File.join(dir, "apps", name, "storeautopilot.yml"))
        assert_equal name, config.app_id
        assert_equal File.realpath(File.join(dir, "apps", name)), File.realpath(config.flutter_dir)
        assert config.monorepo?
        assert_equal "release-#{name}", config.release_branch
        assert File.file?(File.join(dir, "apps", name, "store.md"))
        assert File.file?(File.join(dir, "apps", name, StoreAutopilot::Screenshots::TEST))
        workflow = File.read(config.workflow_file)
        assert_equal File.join(dir, ".github/workflows/store-#{name}.yml"), config.workflow_file
        assert_includes workflow, "name: Store (#{name})"
        assert_includes workflow, "branches: [release-#{name}]"
        assert_includes workflow, "run: storeautopilot release --config apps/#{name}/storeautopilot.yml"
        assert_includes workflow, "run: storeautopilot submit --config apps/#{name}/storeautopilot.yml"
        assert_includes workflow, "group: storeautopilot" # one release at a time in the repository
      end
      refute File.exist?(File.join(dir, "storeautopilot.yml"))
      assert_equal 1, File.read(File.join(dir, ".gitignore")).scan("# StoreAutopilot").size
    end
  end

  def test_doctor_finds_the_apps_workflow_and_branch
    Dir.mktmpdir do |dir|
      repo(dir)
      init(dir, app: "apps/game")
      config = StoreAutopilot::Config.load(File.join(dir, "apps/game/storeautopilot.yml"))
      shell = FakeShell.new("repo view" => JSON.generate(isPrivate: true), "ls-files" => "", "ls-remote" => "")
      checks = StoreAutopilot::Doctor.new(config_path: nil, shell: shell).repo_checks(config)
      assert(checks.any? { |c| c.status == :ok && c.message == ".github/workflows/store-game.yml" })
      assert(checks.any? { |c| c.message.include?("no `release-game` branch") && c.hint.include?("HEAD:release-game") })
    end
  end

  def test_choice_on_the_terminal
    Dir.mktmpdir do |dir|
      repo(dir)
      init(dir, prompt: StoreAutopilot::Prompt.new(input: StringIO.new("2\n" + "\n" * 12)))
      assert File.file?(File.join(dir, "apps/quiz/storeautopilot.yml"))
      refute File.exist?(File.join(dir, "apps/game/storeautopilot.yml"))
    end
  end

  def test_one_app_repositories_stay_as_they_were
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".git"))
      flutter_app(dir, ".", "solo")
      init(dir)
      config = StoreAutopilot::Config.load(File.join(dir, "storeautopilot.yml"))
      refute config.monorepo?
      assert_equal "release", config.release_branch
      workflow = File.read(File.join(dir, ".github/workflows/store.yml"))
      assert_includes workflow, "name: Store\n"
      assert_includes workflow, "run: storeautopilot release\n"
    end
  end
end
