module StoreAutopilot
  VERSION = "1.2.0"
  ROOT = File.expand_path("..", __dir__)
  TEMPLATES = File.join(ROOT, "templates")

  # A problem the user can fix; `hint` says how.
  class Error < StandardError
    # output: the last lines a failed command printed, for callers that can explain them.
    attr_reader :hint, :output

    def initialize(message, hint: nil, output: nil)
      super(message)
      @hint = hint
      @output = output
    end
  end
end

%w[ui prompt shell env cli config listing secrets state privacy importer store_status machine_lock requirements compliance shot_inputs disk summary compose images preview devices screenshots builder fastlane pipeline doctor init runner_install commands].each { |f| require_relative "storeautopilot/#{f}" }
