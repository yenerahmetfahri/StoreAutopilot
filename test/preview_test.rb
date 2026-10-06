require "test_helper"

class PreviewTest < Minitest::Test
  include Fixtures

  def page(dir, md: Fixtures::VALID_MD)
    config = StoreAutopilot::Config.load(make_app(dir))
    store = File.join(dir, "store")
    FileUtils.mkdir_p(File.join(store, "android/metadata/en-US/images/phoneScreenshots"))
    File.write(File.join(store, "android/metadata/en-US/images/phoneScreenshots/01_home.png"), "png")
    File.write(File.join(store, "android/metadata/en-US/images/featureGraphic.png"), "png")
    File.read(StoreAutopilot::Preview.new(config: config, listing: StoreAutopilot::Listing.parse(md), store_dir: store).write)
  end

  def test_shows_both_stores_with_counts_and_images
    Dir.mktmpdir do |dir|
      html = page(dir)
      assert_includes html, "App Store · en-US"
      assert_includes html, "Google Play · en-US"
      assert_includes html, "<span class=\"\">8/30</span>" # "Demo App"
      assert_includes html, %(src="android/metadata/en-US/images/phoneScreenshots/01_home.png")
      refute_includes html, "02_play.png" # not captured, not shown
      assert_includes html, "featureGraphic.png"
      assert_includes html, "No images yet" # iOS side has none
    end
  end

  def test_text_is_escaped_and_over_limit_is_marked
    Dir.mktmpdir do |dir|
      md = Fixtures::VALID_MD.sub("A tiny demo", "<b>#{'x' * 31}</b>")
      html = page(dir, md: md)
      assert_includes html, "&lt;b&gt;"
      assert_includes html, %(<span class="over">38/30</span>)
    end
  end
end
