require "test_helper"

# Loads the real Fastfile with fastlane's DSL and actions replaced by recorders, so lane logic runs without fastlane.
class FastfileHarness
  class UserError < StandardError; end

  module UI
    def self.message(_text) = nil
    def self.user_error!(text) = raise(UserError, text)
  end

  module Spaceship
    module ConnectAPI
      module Platform
        IOS = "IOS"
      end

      class App
        class << self
          attr_accessor :found
        end

        def self.find(_bundle_id) = found
      end
    end
  end

  # An App Store version whose App Review detail exists or not (deliver crashes on a missing one).
  class FakeVersion
    attr_reader :created

    def initialize(has_review_detail:)
      @has = has_review_detail
    end

    def version_string = "1.0.0"
    def fetch_app_store_review_detail = @has ? :detail : raise("No data")
    def create_app_store_review_detail(attributes:) = @created = attributes
  end

  # versions: { edit:, live:, in_review:, pending_release: } → version strings or FakeVersion objects
  class FakeApp
    def initialize(**versions) = @versions = versions

    %i[edit live in_review pending_release].each do |kind|
      define_method("get_#{kind}_app_store_version") do |platform:|
        v = @versions[kind]
        v.is_a?(String) ? Struct.new(:version_string).new(v) : v
      end
    end
  end

  ACTIONS = %i[app_store_connect_api_key latest_testflight_build_number build_app upload_to_testflight
               upload_to_app_store google_play_track_version_codes upload_to_play_store].freeze

  attr_reader :calls

  # stubs: action name => return value, or a proc called with the action's options.
  def initialize(stubs = {})
    @stubs = stubs
    @calls = []
    @lanes = {}
    path = File.join(StoreAutopilot::ROOT, "fastlane", "Fastfile")
    instance_eval(File.read(path), path)
  end

  def default_platform(_name) = nil
  def skip_docs = nil

  def platform(name)
    @platform = name
    yield
  ensure
    @platform = nil
  end

  def lane(name, &block) = @lanes[[@platform, name]] = block

  # Runs a lane with the given job; returns what it wrote to the output file.
  def run(platform, name, job)
    Dir.mktmpdir do |dir|
      job_path = File.join(dir, "job.json")
      output = File.join(dir, "out.json")
      File.write(job_path, JSON.generate(job.merge(output: output, asc_json: write_asc(dir), asc_key: "/k.p8")))
      @job = @asc = nil
      ENV["STOREAUTOPILOT_JOB"] = job_path
      instance_exec(&@lanes.fetch([platform, name]))
      File.file?(output) ? JSON.parse(File.read(output)) : {}
    ensure
      ENV.delete("STOREAUTOPILOT_JOB")
    end
  end

  def called(action) = calls.select { |name, _| name == action }.map(&:last)

  ACTIONS.each do |action|
    define_method(action) do |**opts|
      @calls << [action, opts]
      stub = @stubs[action]
      stub.respond_to?(:call) ? stub.call(opts) : stub
    end
  end

  private

  def write_asc(dir)
    File.join(dir, "asc.json").tap { |p| File.write(p, JSON.generate(key_id: "KEY", issuer_id: "ISSUER")) }
  end
end

class FastfileTest < Minitest::Test
  IOS = { bundle_id: "com.example.demo" }.freeze
  ANDROID = { package: "com.example.demo", play_json: "/play.json", track: "alpha" }.freeze

  def teardown = FastfileHarness::Spaceship::ConnectAPI::App.found = nil

  def test_ios_status_reports_versions_and_build_number
    FastfileHarness::Spaceship::ConnectAPI::App.found = FastfileHarness::FakeApp.new(live: "1.0.0", in_review: "1.1.0")
    lanes = FastfileHarness.new(latest_testflight_build_number: 0)
    assert_equal({ "app" => true, "live_version" => "1.0.0", "in_review_version" => "1.1.0",
                   "pending_release_version" => nil, "build_number" => 0, "last_upload" => nil }, lanes.run(:ios, :status, IOS))
    assert_equal 0, lanes.called(:latest_testflight_build_number).first[:initial_build_number]
  end

  def test_ios_status_reports_a_missing_app
    assert_equal({ "app" => false }, FastfileHarness.new.run(:ios, :status, IOS))
  end

  def test_ios_status_reports_errors_instead_of_failing
    lanes = FastfileHarness.new(app_store_connect_api_key: ->(_) { raise "Authentication failed\nmore" })
    assert_equal({ "error" => "Authentication failed" }, lanes.run(:ios, :status, IOS))
  end

  # gym forwards xcargs to -exportArchive too; passing export_xcargs as well made xcodebuild reject the duplicates.
  def test_ios_upload_passes_auth_args_to_xcodebuild_once
    lanes = FastfileHarness.new
    lanes.run(:ios, :upload, IOS.merge(workspace: "/w/Runner.xcworkspace", build_dir: "/b"))
    build = lanes.called(:build_app).first
    refute build.key?(:export_xcargs)
    assert_equal "/b/app.xcarchive", build[:archive_path]
    assert_equal 1, build[:xcargs].scan("-allowProvisioningUpdates").size
    assert_includes build[:xcargs], "-authenticationKeyID KEY"
    assert_includes build[:xcargs], "-authenticationKeyIssuerID ISSUER"
    testflight = lanes.called(:upload_to_testflight).first
    assert_equal "/b/app.ipa", testflight[:ipa]
    assert_nil testflight[:changelog] # no notes: don't wait for the build at all
    assert_nil testflight[:localized_build_info]
  end

  def test_ios_upload_sets_what_to_test_per_locale
    lanes = FastfileHarness.new
    notes = { "en-US" => "Faster start", "de-DE" => "Schneller Start" }
    lanes.run(:ios, :upload, IOS.merge(workspace: "/w", build_dir: "/b", testflight_notes: notes))
    testflight = lanes.called(:upload_to_testflight).first
    assert_equal "Faster start", testflight[:changelog]
    assert_equal({ "en-US" => { whats_new: "Faster start" }, "de-DE" => { whats_new: "Schneller Start" } }, testflight[:localized_build_info])
  end

  # deliver crashes with "No data" when the version has no App Review detail yet (an app's first version).
  def test_ios_metadata_creates_missing_review_detail
    version = FastfileHarness::FakeVersion.new(has_review_detail: false)
    FastfileHarness::Spaceship::ConnectAPI::App.found = FastfileHarness::FakeApp.new(edit: version)
    lanes = FastfileHarness.new
    lanes.run(:ios, :metadata, IOS.merge(version: "1.0.0", metadata_path: "/m", screenshots_path: nil))
    assert_equal({ demo_account_required: false }, version.created)
    upload = lanes.called(:upload_to_app_store).first
    assert_equal "/m", upload[:metadata_path]
    refute upload[:skip_metadata]
    assert upload[:skip_screenshots]
    refute upload[:submit_for_review]
  end

  def test_ios_metadata_keeps_existing_review_detail
    version = FastfileHarness::FakeVersion.new(has_review_detail: true)
    FastfileHarness::Spaceship::ConnectAPI::App.found = FastfileHarness::FakeApp.new(edit: version)
    FastfileHarness.new.run(:ios, :metadata, IOS.merge(version: "1.0.0", metadata_path: "/m"))
    assert_nil version.created
  end

  def test_ios_metadata_explains_a_missing_app_record
    lanes = FastfileHarness.new
    err = assert_raises(FastfileHarness::UserError) { lanes.run(:ios, :metadata, IOS.merge(version: "1.0.0")) }
    assert_includes err.message, "Create the app record"
    assert_empty lanes.called(:upload_to_app_store)
  end

  def test_ios_submit_sends_the_latest_build_of_the_version
    lanes = FastfileHarness.new(latest_testflight_build_number: 12)
    assert_equal({ "build_number" => 12 }, lanes.run(:ios, :submit, IOS.merge(version: "1.2.0")))
    submit = lanes.called(:upload_to_app_store).first
    assert_equal "12", submit[:build_number]
    assert submit[:submit_for_review]
    assert submit[:skip_metadata]
  end

  def test_android_status_lists_tracks_and_unreadable_ones
    codes = { "internal" => ["3"], "alpha" => [7, 5], "beta" => [], "production" => nil }
    lanes = FastfileHarness.new(google_play_track_version_codes: ->(o) { codes[o[:track]] || raise("Track not found\nx") })
    assert_equal({ "tracks" => { "internal" => [3], "alpha" => [7, 5], "beta" => [] }, "errors" => { "production" => "Track not found" } },
                 lanes.run(:android, :status, ANDROID))
  end

  def test_android_status_with_nothing_readable_is_an_error
    lanes = FastfileHarness.new(google_play_track_version_codes: ->(_) { raise "Connection reset" })
    assert_equal "Connection reset", lanes.run(:android, :status, ANDROID)["error"]
  end

  def test_android_upload_sends_only_the_bundle
    lanes = FastfileHarness.new
    lanes.run(:android, :upload, ANDROID.merge(aab: "/a.aab", release_status: "completed", metadata_path: "/m"))
    upload = lanes.called(:upload_to_play_store).first
    assert_equal ["/a.aab", "alpha"], upload.values_at(:aab, :track)
    assert upload[:skip_upload_metadata]
    assert upload[:skip_upload_images]
  end

  # supply looks for a release with version code nil and fails unless it is told which release to attach to.
  def test_android_metadata_attaches_to_the_newest_release_on_the_track
    lanes = FastfileHarness.new(google_play_track_version_codes: [4, "9", 6])
    lanes.run(:android, :metadata, ANDROID.merge(metadata_path: "/m", text: true, images: false))
    upload = lanes.called(:upload_to_play_store).first
    assert_equal 9, upload[:version_code]
    assert_equal "alpha", upload[:track]
    refute upload[:skip_upload_metadata]
    assert upload[:skip_upload_images]
    assert upload[:skip_upload_changelogs]
  end

  def test_android_metadata_fails_on_an_empty_track
    lanes = FastfileHarness.new(google_play_track_version_codes: [])
    err = assert_raises(FastfileHarness::UserError) { lanes.run(:android, :metadata, ANDROID.merge(metadata_path: "/m")) }
    assert_includes err.message, "alpha"
    assert_empty lanes.called(:upload_to_play_store)
  end

  def test_android_promote_can_start_a_staged_rollout
    lanes = FastfileHarness.new(google_play_track_version_codes: [11])
    lanes.run(:android, :promote, ANDROID.merge(rollout: 0.2))
    assert_equal "0.2", lanes.called(:upload_to_play_store).first[:rollout]
  end

  def test_android_halt_keeps_the_current_share
    lanes = FastfileHarness.new
    lanes.run(:android, :halt, ANDROID.merge(rollout: 0.2))
    halt = lanes.called(:upload_to_play_store).first
    assert_equal ["production", "halted", "0.2"], halt.values_at(:track, :release_status, :rollout)
  end

  def test_android_rollout_updates_production
    lanes = FastfileHarness.new
    lanes.run(:android, :rollout, ANDROID.merge(rollout: 1.0))
    update = lanes.called(:upload_to_play_store).first
    assert_equal ["production", "1.0"], update.values_at(:track, :rollout)
    assert update[:skip_upload_aab]
    refute update.key?(:track_promote_to)
  end

  def test_ios_submit_declares_content_rights_when_missing
    app = FastfileHarness::FakeApp.new
    app.define_singleton_method(:content_rights_declaration) { nil }
    app.define_singleton_method(:update) { |attributes:| @updated = attributes }
    FastfileHarness::Spaceship::ConnectAPI::App.found = app
    FastfileHarness.new(latest_testflight_build_number: 3)
                   .run(:ios, :submit, IOS.merge(version: "1.2.0", content_rights: "DOES_NOT_USE_THIRD_PARTY_CONTENT"))
    assert_equal({ content_rights_declaration: "DOES_NOT_USE_THIRD_PARTY_CONTENT" }, app.instance_variable_get(:@updated))
  end

  def test_ios_submit_phased_release
    lanes = FastfileHarness.new(latest_testflight_build_number: 3)
    lanes.run(:ios, :submit, IOS.merge(version: "1.2.0", phased_release: true))
    assert lanes.called(:upload_to_app_store).first[:phased_release]
  end

  def test_android_promote_moves_the_newest_release_to_production
    lanes = FastfileHarness.new(google_play_track_version_codes: [8, 11])
    assert_equal({ "version_code" => 11 }, lanes.run(:android, :promote, ANDROID))
    promote = lanes.called(:upload_to_play_store).first
    assert_equal ["production", 11, "completed"], promote.values_at(:track_promote_to, :version_code, :release_status)
    assert_nil promote[:rollout]
  end
end

class FastfileReadinessTest < Minitest::Test
  # The 2025 age rating questions count: answering only the old ones is not enough.
  def test_unanswered_new_age_rating_questions_are_reported
    lanes = FastfileHarness.new
    questions = lanes.singleton_class::AGE_QUESTIONS
    age = Struct.new(*questions).new
    (questions - %i[messaging_and_chat user_generated_content]).each { |q| age[q] = "NONE" }
    assert_equal %i[messaging_and_chat user_generated_content], lanes.unanswered_age_questions(age)
    assert_equal questions, lanes.unanswered_age_questions(nil)
  end
end
