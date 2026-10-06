module StoreAutopilot
  # Turns raw captures into the folder layouts deliver (iOS) and supply (Android) upload.
  class Images
    SIZES = { ios: [1320, 2868], ipad: [2064, 2752], android: [1080, 1920] }.freeze
    FEATURE = [1024, 500].freeze

    def initialize(config:, listing:, compose:)
      @config = config
      @listing = listing
      @compose = compose
    end

    def build(platform, raw_dir:, out_dir:)
      width, height = SIZES.fetch(platform)
      @config.locales.each do |id, codes|
        fields = @listing.locales.fetch(id)
        @config.screenshots.each do |shot|
          raw = File.join(raw_dir, platform.to_s, id, "#{shot}.png")
          unless File.file?(raw)
            raise Error.new("Missing #{platform} screenshot #{raw}",
                            hint: "Your integration test must call takeStoreScreenshot(tester, '#{shot}').")
          end
          # deliver tells iPhone and iPad images apart by size; the prefix only keeps the file names apart.
          out = if platform == :ios
                  File.join(out_dir, "screenshots", codes[:apple], "#{shot}.png")
                elsif platform == :ipad
                  File.join(out_dir, "screenshots", codes[:apple], "ipad_#{shot}.png")
                else
                  File.join(out_dir, "metadata", codes[:play], "images", "phoneScreenshots", "#{shot}.png")
                end
          vars = brand_vars.merge(caption: fields["captions"].fetch(shot), screenshot: "file://#{raw}", platform: platform)
          @compose.render(template: @config.template_path("frame.html"), vars: vars, width: width, height: height, out: out)
        end
        next unless platform == :android
        @compose.render(template: @config.template_path("feature.html"),
                        vars: brand_vars.merge(name: fields["name"], tagline: fields["short_description"]),
                        width: FEATURE[0], height: FEATURE[1],
                        out: File.join(out_dir, "metadata", codes[:play], "images", "featureGraphic.png"))
      end
      out_dir
    end

    private

    def brand_vars = @config.brand.slice(:background, :text, :accent, :font)
  end
end
