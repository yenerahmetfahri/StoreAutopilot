require "test_helper"

class ImagesTest < Minitest::Test
  include Fixtures

  # Records render calls instead of launching Chrome.
  class FakeCompose
    attr_reader :calls
    def initialize = @calls = []
    def render(template:, vars:, width:, height:, out:)
      @calls << { template: File.basename(template), vars: vars, size: [width, height], out: out }
      FileUtils.mkdir_p(File.dirname(out))
      File.write(out, "png")
    end
  end

  def setup_app(dir)
    config = StoreAutopilot::Config.load(make_app(dir))
    listing = StoreAutopilot::Listing.parse(Fixtures::VALID_MD)
    %w[ios ipad android].each do |p|
      FileUtils.mkdir_p(File.join(dir, "raw", p, "en"))
      config.screenshots.each { |s| File.write(File.join(dir, "raw", p, "en", "#{s}.png"), "raw") }
    end
    [config, listing]
  end

  def test_ios_tree
    Dir.mktmpdir do |dir|
      config, listing = setup_app(dir)
      fake = FakeCompose.new
      StoreAutopilot::Images.new(config: config, listing: listing, compose: fake).build(:ios, raw_dir: File.join(dir, "raw"), out_dir: File.join(dir, "out"))
      assert_equal 2, fake.calls.size
      first = fake.calls.first
      assert_equal [1320, 2868], first[:size]
      assert_equal "Your home screen", first[:vars][:caption]
      assert_equal "file://#{File.join(dir, 'raw', 'ios', 'en', '01_home.png')}", first[:vars][:screenshot]
      assert_equal File.join(dir, "out", "screenshots", "en-US", "01_home.png"), first[:out]
    end
  end

  def test_ipad_images_go_next_to_the_iphone_ones
    Dir.mktmpdir do |dir|
      config, listing = setup_app(dir)
      fake = FakeCompose.new
      StoreAutopilot::Images.new(config: config, listing: listing, compose: fake).build(:ipad, raw_dir: File.join(dir, "raw"), out_dir: File.join(dir, "out"))
      assert_equal [[2064, 2752]] * 2, fake.calls.map { |c| c[:size] }
      assert_equal File.join(dir, "out", "screenshots", "en-US", "ipad_01_home.png"), fake.calls.first[:out]
      assert_equal :ipad, fake.calls.first[:vars][:platform]
    end
  end

  def test_android_tree_includes_feature_graphic
    Dir.mktmpdir do |dir|
      config, listing = setup_app(dir)
      fake = FakeCompose.new
      StoreAutopilot::Images.new(config: config, listing: listing, compose: fake).build(:android, raw_dir: File.join(dir, "raw"), out_dir: File.join(dir, "out"))
      assert_equal [[1080, 1920], [1080, 1920], [1024, 500]], fake.calls.map { |c| c[:size] }
      assert_equal File.join(dir, "out", "metadata", "en-US", "images", "phoneScreenshots", "02_play.png"), fake.calls[1][:out]
      assert_equal "feature.html", fake.calls[2][:template]
      assert_equal "Demo App", fake.calls[2][:vars][:name]
    end
  end

  def test_missing_raw_screenshot_has_hint
    Dir.mktmpdir do |dir|
      config, listing = setup_app(dir)
      File.delete(File.join(dir, "raw", "ios", "en", "02_play.png"))
      err = assert_raises(StoreAutopilot::Error) do
        StoreAutopilot::Images.new(config: config, listing: listing, compose: FakeCompose.new).build(:ios, raw_dir: File.join(dir, "raw"), out_dir: File.join(dir, "out"))
      end
      assert_includes err.hint, "takeStoreScreenshot"
    end
  end
end
