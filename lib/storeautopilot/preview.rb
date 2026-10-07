require "cgi"
require "fileutils"

module StoreAutopilot
  # One HTML page showing, per language, roughly how the App Store and Google Play pages will read: text with
  # character counts against the limits, the store images from the last `shots`, and the text advice. Nothing is
  # uploaded; it is for reading before a release.
  class Preview
    def initialize(config:, listing:, store_dir:)
      @config = config
      @listing = listing
      @store_dir = store_dir
    end

    def write
      FileUtils.mkdir_p(@store_dir)
      path = File.join(@store_dir, "preview.html")
      File.write(path, html)
      path
    end

    def html
      sections = @config.locales.map do |id, codes|
        stores = []
        stores << apple(@listing.fields_for(id, :ios), codes[:apple]) if @config.ios?
        stores << play(@listing.fields_for(id, :android), codes[:play]) if @config.android?
        %(<section><h2>#{h(id)}</h2><div class="stores">#{stores.join}</div></section>)
      end
      advice = @config.feature?(:text_advice) ? @listing.advice(@config) : []
      notes = advice.empty? ? "" : %(<aside><h2>Suggestions</h2><ul>#{advice.map { |a| "<li>#{h(a)}</li>" }.join}</ul></aside>)
      <<~HTML
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Store preview</title><style>#{CSS}</style></head>
        <body><header><h1>Store preview</h1><p>Version #{h(@config.version_name)} · images from the last <code>storeautopilot shots</code></p></header>
        #{notes}#{sections.join}</body></html>
      HTML
    end

    CSS = <<~CSS.freeze
      :root { --bg: #f5f5f7; --card: #fff; --text: #1d1d1f; --muted: #6e6e73; --line: #e5e5ea; --bad: #c62828; }
      @media (prefers-color-scheme: dark) { :root { --bg: #1c1c1e; --card: #2c2c2e; --text: #f5f5f7; --muted: #a1a1a6; --line: #3a3a3c; --bad: #ff6b6b; } }
      * { box-sizing: border-box; }
      body { margin: 0; padding: 24px 16px 64px; background: var(--bg); color: var(--text); font: 15px/1.5 -apple-system, "Segoe UI", Roboto, sans-serif; }
      header, section, aside { max-width: 1200px; margin: 0 auto 24px; }
      h1 { margin: 0; font-size: 28px; } header p { margin: 4px 0 0; color: var(--muted); }
      h2 { font-size: 20px; margin: 0 0 12px; }
      aside { background: var(--card); border-radius: 14px; padding: 16px 20px; } aside li { margin: 4px 0; }
      .stores { display: grid; grid-template-columns: repeat(auto-fit, minmax(340px, 1fr)); gap: 16px; }
      .store { background: var(--card); border-radius: 14px; padding: 20px; min-width: 0; }
      .store > h3 { margin: 0 0 12px; font-size: 13px; text-transform: uppercase; letter-spacing: .06em; color: var(--muted); }
      .name { font-size: 22px; font-weight: 700; } .sub { color: var(--muted); }
      .field { margin-top: 14px; } .label { font-size: 12px; color: var(--muted); display: flex; justify-content: space-between; }
      .over { color: var(--bad); font-weight: 600; }
      .text { white-space: pre-wrap; overflow-wrap: anywhere; }
      .shots { display: flex; gap: 8px; overflow-x: auto; padding: 4px 0; margin-top: 14px; }
      .shots img { height: 300px; border-radius: 10px; border: 1px solid var(--line); }
      .feature { width: 100%; border-radius: 10px; border: 1px solid var(--line); margin-top: 14px; }
      .missing { color: var(--muted); font-style: italic; margin-top: 14px; }
    CSS

    private

    def apple(fields, code)
      shots = images(@config.screenshots.map { |s| "ios/screenshots/#{code}/#{s}.png" }) +
              images(@config.screenshots.map { |s| "ios/screenshots/#{code}/ipad_#{s}.png" })
      <<~HTML
        <div class="store"><h3>App Store · #{h(code)}</h3>
        <div class="name">#{h(fields['name'])}</div><div class="sub">#{h(fields['subtitle'])}</div>
        #{shot_row(shots)}
        #{field('Promotional text', fields['promotional_text'], :ios, 'promotional_text')}
        #{field('Description', fields['description'], :ios, 'description')}
        #{field("What's New", fields['release_notes'], :ios, 'release_notes')}
        #{field('Keywords (not shown in the store)', fields['keywords'], :ios, 'keywords')}
        #{counter_only('Name', fields['name'], :ios, 'name')}#{counter_only('Subtitle', fields['subtitle'], :ios, 'subtitle')}
        </div>
      HTML
    end

    def play(fields, code)
      base = "android/metadata/#{code}/images"
      feature = File.file?(File.join(@store_dir, base, "featureGraphic.png")) ? %(<img class="feature" src="#{base}/featureGraphic.png" alt="">) : ""
      <<~HTML
        <div class="store"><h3>Google Play · #{h(code)}</h3>
        <div class="name">#{h(fields['name'])}</div>
        #{feature}
        #{shot_row(images(@config.screenshots.map { |s| "#{base}/phoneScreenshots/#{s}.png" }))}
        #{field('Short description', fields['short_description'], :android, 'short_description')}
        #{field('Full description', fields['description'], :android, 'description')}
        #{field("What's new", fields['release_notes'], :android, 'release_notes')}
        #{counter_only('Title', fields['name'], :android, 'name')}
        </div>
      HTML
    end

    def images(rels) = rels.select { |rel| File.file?(File.join(@store_dir, rel)) }

    def shot_row(rels)
      return %(<div class="missing">No images yet: run <code>storeautopilot shots</code>.</div>) if rels.empty?
      %(<div class="shots">#{rels.map { |rel| %(<img src="#{h(rel)}" alt="">) }.join}</div>)
    end

    def field(label, text, platform, key)
      return "" if text.to_s.empty?
      %(<div class="field">#{counter(label, text, platform, key)}<div class="text">#{h(text)}</div></div>)
    end

    def counter_only(label, text, platform, key) = %(<div class="field">#{counter(label, text, platform, key)}</div>)

    def counter(label, text, platform, key)
      max = Listing::LIMITS.dig(platform, key)
      count = text.to_s.length
      tally = max ? %(<span class="#{'over' if count > max}">#{count}/#{max}</span>) : ""
      %(<div class="label"><span>#{h(label)}</span>#{tally}</div>)
    end

    def h(text) = CGI.escapeHTML(text.to_s)
  end
end
