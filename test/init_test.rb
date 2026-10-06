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
