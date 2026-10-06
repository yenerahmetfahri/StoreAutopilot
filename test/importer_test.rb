require "test_helper"

class ImporterTest < Minitest::Test
  include Fixtures

  APPLE = {
    "app" => true, "copyright" => "2026 Example", "apple_category" => "PRODUCTIVITY",
    "locales" => {
      "en-US" => { "name" => "Demo App", "subtitle" => "Tiny demo", "keywords" => "demo,example", "description" => "From Apple.",
                   "promotional_text" => nil, "release_notes" => "Fixes.", "support_url" => "https://example.com/s",
                   "privacy_url" => "https://example.com/p", "marketing_url" => nil },
      "fr-FR" => { "name" => "Démo" }
    }
  }.freeze
  PLAY = { "locales" => { "en-US" => { "name" => "Demo App", "short_description" => "A short one.", "description" => "From Google." } } }.freeze

  def build(dir, existing: nil)
    warnings = []
    text = StoreAutopilot::Importer.build(config: StoreAutopilot::Config.load(make_app(dir)), apple: APPLE, play: PLAY,
                                          existing: existing) { |w| warnings << w }
    [text, warnings]
  end

  def test_builds_a_valid_store_md_from_both_stores
    Dir.mktmpdir do |dir|
      text, warnings = build(dir)
      listing = StoreAutopilot::Listing.parse(text).validate!(StoreAutopilot::Config.load(File.join(dir, "storeautopilot.yml")))
      en = listing.locales["en"]
      assert_equal ["Demo App", "Tiny demo", "From Apple.", "A short one.", "Fixes."], en.values_at("name", "subtitle", "description", "short_description", "release_notes")
      assert_equal "https://example.com/p", listing.meta["privacy_url"]
      assert_equal "PRODUCTIVITY", listing.meta["apple_category"]
      refute listing.meta.key?("marketing_url")
      assert_equal "Caption for 01_home", en["captions"]["01_home"]
      assert(warnings.any? { |w| w.include?("different descriptions") })
      assert(warnings.any? { |w| w.include?("fr-FR") })
    end
  end

  def test_keeps_captions_and_review_details_from_the_existing_store_md
    Dir.mktmpdir do |dir|
      existing = StoreAutopilot::Listing.parse(Fixtures::VALID_MD.sub("---\n", "---\nreview_notes: No login.\n"))
      text, = build(dir, existing: existing)
      listing = StoreAutopilot::Listing.parse(text)
      assert_equal "Your home screen", listing.locales["en"]["captions"]["01_home"]
      assert_equal "No login.", listing.meta["review_notes"]
    end
  end

  def test_lines_starting_with_hash_cannot_break_the_file
    Dir.mktmpdir do |dir|
      apple = APPLE.merge("locales" => { "en-US" => APPLE["locales"]["en-US"].merge("description" => "Intro\n# Features\nMore") })
      text = StoreAutopilot::Importer.build(config: StoreAutopilot::Config.load(make_app(dir)), apple: apple, play: PLAY)
      assert_includes StoreAutopilot::Listing.parse(text).locales["en"]["description"], "# Features"
    end
  end

  def test_run_never_overwrites_store_md
    Dir.mktmpdir do |dir|
      home = File.join(dir, "home")
      make_secrets(home)
      config = StoreAutopilot::Config.load(make_app(dir))
      fastlane = Object.new
      fastlane.define_singleton_method(:lane) { |platform, *, **| platform == :ios ? APPLE : PLAY }
      original = File.read(config.listing_path)
      path = StoreAutopilot::Importer.new(config: config, fastlane: fastlane, secrets: StoreAutopilot::Secrets.new("demo-app", home: home)).run
      assert_equal File.join(dir, "store.imported.md"), path
      assert_equal original, File.read(config.listing_path)
      assert_includes File.read(path), "From Apple."
    end
  end
end
