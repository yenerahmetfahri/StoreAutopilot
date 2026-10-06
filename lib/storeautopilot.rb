module StoreAutopilot
  ROOT = File.expand_path("..", __dir__)
  TEMPLATES = File.join(ROOT, "templates")

  # A problem the user can fix; `hint` says how.
  class Error < StandardError
    attr_reader :hint

    def initialize(message, hint: nil)
      super(message)
      @hint = hint
    end
  end
end

%w[ui prompt shell env cli config listing secrets state privacy importer store_status shot_inputs disk summary compose images preview devices screenshots builder fastlane pipeline doctor init runner_install commands].each { |f| require_relative "storeautopilot/#{f}" }
