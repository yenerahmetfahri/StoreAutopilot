require "test_helper"

class StateTest < Minitest::Test
  def test_digest_changes_with_content_and_respects_filters
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "en", "changelogs"))
      File.write(File.join(dir, "en", "title.txt"), "A")
      File.write(File.join(dir, "en", "changelogs", "1.txt"), "x")
      base = StoreAutopilot::State.digest(dir, except: %r{(\A|/)changelogs/})
      File.write(File.join(dir, "en", "changelogs", "2.txt"), "y")
      assert_equal base, StoreAutopilot::State.digest(dir, except: %r{(\A|/)changelogs/})
      refute_equal base, StoreAutopilot::State.digest(dir)
      File.write(File.join(dir, "en", "title.txt"), "B")
      refute_equal base, StoreAutopilot::State.digest(dir, except: %r{(\A|/)changelogs/})
      assert_equal StoreAutopilot::State.digest(File.join(dir, "missing")), StoreAutopilot::State.digest(File.join(dir, "missing2"))
    end
  end

  def test_record_persists_privately
    Dir.mktmpdir do |dir|
      path = File.join(dir, "state.json")
      s = StoreAutopilot::State.new(path)
      assert s.changed?("ios_text", "abc")
      s.record("ios_text", "abc")
      s2 = StoreAutopilot::State.new(path)
      refute s2.changed?("ios_text", "abc")
      assert_equal "abc", s2["ios_text"]
      assert_equal 0o600, File.stat(path).mode & 0o777
    end
  end
end
