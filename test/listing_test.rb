require "test_helper"

class ListingTest < Minitest::Test
  include Fixtures

  def listing = StoreAutopilot::Listing.parse(Fixtures::VALID_MD)

  def test_parses_front_matter_fields_and_captions
    l = listing
    assert_equal "https://demo.example.org/privacy", l.meta["privacy_url"]
    assert_equal "Demo App", l.locales["en"]["name"]
    assert_equal "demo,example", l.locales["en"]["keywords"]
    assert_equal({ "01_home" => "Your home screen", "02_play" => "Play anywhere" }, l.locales["en"]["captions"])
  end

  def test_front_matter_must_be_a_mapping
    err = assert_raises(StoreAutopilot::Error) { StoreAutopilot::Listing.parse("---\njust text\n---\n# en\n") }
    assert_includes err.message, "mapping"
  end

  def test_unknown_section_is_an_error
    err = assert_raises(StoreAutopilot::Error) { StoreAutopilot::Listing.parse("# en\n## titel\nx\n") }
    assert_includes err.message, "titel"
  end

  def test_validate_reports_limits_missing_fields_and_captions
    md = Fixtures::VALID_MD.sub("Demo App", "D" * 31).sub("- 02_play: Play anywhere\n", "").sub("## keywords\ndemo,example\n", "")
    Dir.mktmpdir do |dir|
      config = StoreAutopilot::Config.load(make_app(dir))
      err = assert_raises(StoreAutopilot::Error) { StoreAutopilot::Listing.parse(md).validate!(config) }
      assert_includes err.message, "en/name: 31 characters"
      assert_includes err.message, "en/keywords: required for ios"
      assert_includes err.message, "no caption for `02_play`"
    end
  end

  def test_validate_passes_for_fixture
    Dir.mktmpdir { |dir| assert listing.validate!(StoreAutopilot::Config.load(make_app(dir))) }
  end

  def test_writes_deliver_and_supply_trees
    Dir.mktmpdir do |dir|
      config = StoreAutopilot::Config.load(make_app(dir))
      apple = File.join(dir, "apple")
      play = File.join(dir, "play")
      listing.write_apple(apple, config)
      listing.write_play(play, config, version_code: 12)
      assert_equal "Demo App\n", File.read(File.join(apple, "en-US", "name.txt"))
      assert_equal "https://demo.example.org/support\n", File.read(File.join(apple, "en-US", "support_url.txt"))
      assert_equal "2026 Example\n", File.read(File.join(apple, "copyright.txt"))
      refute File.exist?(File.join(apple, "en-US", "marketing_url.txt"))
      assert_equal "A short one.\n", File.read(File.join(play, "en-US", "short_description.txt"))
      assert_equal "Bug fixes.\n", File.read(File.join(play, "en-US", "changelogs", "12.txt"))
    end
  end

  def test_review_contact_and_demo_account_go_to_review_information
    md = Fixtures::VALID_MD.sub("---\n", "---\nreview_contact: { first_name: Jane, last_name: Doe, phone: \"+1 555 010 0100\", email: jane@example.com }\nreview_demo_user: rev@example.com\n")
    Dir.mktmpdir do |dir|
      config = StoreAutopilot::Config.load(make_app(dir))
      listing = StoreAutopilot::Listing.parse(md).validate!(config)
      review = File.join(listing.write_apple(File.join(dir, "out"), config, demo_password: "s3cret"), "review_information")
      { "first_name" => "Jane", "last_name" => "Doe", "phone_number" => "+1 555 010 0100", "email_address" => "jane@example.com",
        "demo_user" => "rev@example.com", "demo_password" => "s3cret" }.each do |file, value|
        assert_equal "#{value}\n", File.read(File.join(review, "#{file}.txt")), file
      end
      assert_equal 0o600, File.stat(File.join(review, "demo_password.txt")).mode & 0o777
    end
  end

  def test_review_contact_is_checked
    md = Fixtures::VALID_MD.sub("---\n", "---\nreview_contact: { first_name: J, phone: \"555 0100\", email: nope, mobile: x }\n")
    Dir.mktmpdir do |dir|
      config = StoreAutopilot::Config.load(make_app(dir))
      err = assert_raises(StoreAutopilot::Error) { StoreAutopilot::Listing.parse(md).validate!(config) }
      %w[review_contact.mobile review_contact.email country\ code].each { |w| assert_includes err.message, w }
    end
  end

  # App Review notes are app-level: front matter `review_notes` → deliver's review_information/notes.txt.
  def test_writes_review_notes_for_apple
    md = Fixtures::VALID_MD.sub("---\n", "---\nreview_notes: |\n  No login needed.\n  Duel works offline.\n")
    Dir.mktmpdir do |dir|
      config = StoreAutopilot::Config.load(make_app(dir))
      apple = File.join(dir, "apple")
      StoreAutopilot::Listing.parse(md).write_apple(apple, config)
      assert_equal "No login needed.\nDuel works offline.\n", File.read(File.join(apple, "review_information", "notes.txt"))
      listing.write_apple(File.join(dir, "plain"), config)
      refute File.exist?(File.join(dir, "plain", "review_information", "notes.txt"))
    end
  end
end

class ListingAdviceTest < Minitest::Test
  include Fixtures

  def advice(md)
    Dir.mktmpdir { |dir| StoreAutopilot::Listing.parse(md).advice(StoreAutopilot::Config.load(make_app(dir))) }
  end

  def test_clean_listing_has_no_advice
    md = Fixtures::VALID_MD.sub("A tiny demo", "Small and quick")
                           .sub("demo,example", "sample,example,starter,template,trial,showcase,preview,tryout,playground,sandbox,mockup,prototype")
    assert_equal [], advice(md)
  end

  def test_keyword_waste
    md = Fixtures::VALID_MD.sub("demo,example", "demo, example ,puzzle,Puzzle,app,tiny,words,daily,brain,quiz,trivia,letters,fun")
    text = advice(md).join("\n")
    assert_includes text, "remove the 2 space(s)"
    assert_includes text, "puzzle listed twice"
    assert_includes text, "demo, app, tiny already in the name or subtitle"
  end

  def test_subtitle_captions_and_release_notes
    md = Fixtures::VALID_MD.sub("A tiny demo", "The Demo App for you").sub("Bug fixes.\n", "")
                           .sub("Your home screen", "Your home screen with everything you need, right where you want it")
    text = advice(md).join("\n")
    assert_includes text, "subtitle repeats demo, app from the name"
    assert_includes text, "release_notes is empty"
    assert_includes text, "captions/01_home: 66 characters"
  end

  def split_listing
    md = Fixtures::VALID_MD.sub("## release_notes", "## android_description\nThe Play description.\n## release_notes")
    StoreAutopilot::Listing.parse(md)
  end

  def test_a_store_section_replaces_the_shared_text_in_that_store_only
    l = split_listing
    assert_equal "The demo app description.", l.fields_for("en", :ios)["description"]
    assert_equal "The Play description.", l.fields_for("en", :android)["description"]
    assert_equal "Demo App", l.fields_for("en", :android)["name"]
    Dir.mktmpdir do |dir|
      config = StoreAutopilot::Config.load(make_app(dir))
      apple = l.write_apple(File.join(dir, "apple"), config)
      play = l.write_play(File.join(dir, "play"), config, version_code: 1)
      assert_equal "The demo app description.\n", File.read(File.join(apple, "en-US", "description.txt"))
      assert_equal "The Play description.\n", File.read(File.join(play, "en-US", "full_description.txt"))
    end
  end

  def test_store_sections_are_checked_against_that_stores_limits
    md = Fixtures::VALID_MD.sub("## release_notes", "## android_name\n#{'N' * 31}\n## release_notes")
    Dir.mktmpdir do |dir|
      config = StoreAutopilot::Config.load(make_app(dir))
      err = assert_raises(StoreAutopilot::Error) { StoreAutopilot::Listing.parse(md).validate!(config) }
      assert_includes err.message, "en/name: 31 characters, android allows 30"
      refute_includes err.message, "ios allows"
    end
  end
end
