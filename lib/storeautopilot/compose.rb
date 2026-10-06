require "cgi"
require "tmpdir"
require "fileutils"

module StoreAutopilot
  # Renders an HTML template to a PNG of an exact size with headless Chrome.
  class Compose
    CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

    # Replaces {{key}} with HTML-escaped values; unknown keys are an error.
    def self.fill(template, vars)
      template.gsub(/\{\{\s*(\w+)\s*\}\}/) do
        key = Regexp.last_match(1).to_sym
        raise Error.new("Template uses unknown {{#{key}}}", hint: "Available: #{vars.keys.join(', ')}") unless vars.key?(key)
        CGI.escapeHTML(vars[key].to_s)
      end
    end

    def self.png_size(path)
      head = File.binread(path, 24)
      raise Error.new("#{path} is not a PNG") unless head && head.start_with?("\x89PNG".b)
      head[16, 8].unpack("NN")
    end

    def initialize(shell:, chrome: CHROME)
      @shell = shell
      @chrome = chrome
    end

    def render(template:, vars:, width:, height:, out:)
      raise Error.new("Google Chrome not found at #{@chrome}", hint: "Install Google Chrome.") unless File.executable?(@chrome)
      FileUtils.mkdir_p(File.dirname(out))
      Dir.mktmpdir("storeautopilot") do |tmp|
        page = File.join(tmp, "page.html")
        File.write(page, self.class.fill(File.read(template), vars.merge(width: width, height: height)))
        @shell.capture(@chrome, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--force-device-scale-factor=1",
                       "--window-size=#{width},#{height}",
                       "--virtual-time-budget=3000", "--screenshot=#{out}", "file://#{page}", timeout: 60)
      end
      size = self.class.png_size(out)
      return out if size == [width, height]
      raise Error.new("Rendered #{File.basename(out)} is #{size.join('x')}, expected #{width}x#{height}")
    end
  end
end
