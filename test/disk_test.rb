require "test_helper"

class DiskTest < Minitest::Test
  include Fixtures

  def df(available_kb) = "Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/disk1 1 1 #{available_kb} 99% /\n"

  def test_reads_free_space
    assert_in_delta 100.0, StoreAutopilot::Disk.free_gb(FakeShell.new, "/")
    assert_nil StoreAutopilot::Disk.free_gb(FakeShell.new("df -Pk" => ""), "/")
  end

  def test_real_df_output_parses
    assert_operator StoreAutopilot::Disk.free_gb(StoreAutopilot::Shell.new, Dir.home), :>, 0
  end

  # A nearly full disk fails the release before anything is built, not 15 minutes in.
  def test_release_stops_on_a_full_disk
    Dir.mktmpdir do |dir|
      home = File.join(dir, "home")
      make_secrets(home)
      config = StoreAutopilot::Config.load(make_app(dir))
      shell = FakeShell.new("df -Pk" => df(300 * 1024))
      err = assert_raises(StoreAutopilot::Error) { StoreAutopilot::Pipeline.new(config: config, shell: shell, home: home).release }
      assert_includes err.message, "Only 0.3 GB free"
      assert_includes err.hint, "DerivedData"
      assert_empty shell.runs
    end
  end

  def test_doctor_grades_free_space
    doctor = ->(kb) { StoreAutopilot::Doctor.new(config_path: nil, shell: FakeShell.new("df -Pk" => df(kb))).send(:disk_check) }
    assert_equal :ok, doctor.call(20 * 1024 * 1024).status
    assert_equal :warn, doctor.call(8 * 1024 * 1024).status
    assert_equal :fail, doctor.call(1 * 1024 * 1024).status
  end
end
