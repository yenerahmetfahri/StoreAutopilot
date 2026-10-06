require "test_helper"

class ComposeTest < Minitest::Test
  C = StoreAutopilot::Compose

  def test_fill_escapes_and_rejects_unknown_keys
    assert_equal "<h1>a &amp; &lt;b&gt;</h1>", C.fill("<h1>{{ caption }}</h1>", caption: "a & <b>")
    err = assert_raises(StoreAutopilot::Error) { C.fill("{{nope}}", caption: "x") }
    assert_includes err.message, "{{nope}}"
  end

  def test_renders_exact_size_with_chrome
    skip "Chrome not installed" unless File.executable?(C::CHROME)
    Dir.mktmpdir do |dir|
      tpl = File.join(dir, "t.html")
      File.write(tpl, "<body style='margin:0;background:{{background}}'></body>")
      out = File.join(dir, "o.png")
      C.new(shell: StoreAutopilot::Shell.new).render(template: tpl, vars: { background: "#123456" }, width: 300, height: 500, out: out)
      assert_equal [300, 500], C.png_size(out)
    end
  end
end
