module StoreAutopilot
  # Questions on the terminal, for `init`. An empty answer takes the default.
  class Prompt
    def initialize(input: $stdin)
      @input = input
    end

    def ask(question, default: nil)
      UI.output("  #{question}#{" [#{default}]" if default && !default.to_s.empty?}: ")
      answer = @input.gets.to_s.strip
      UI.log_only(answer)
      answer.empty? ? default.to_s : answer
    end

    def yes?(question, default: false)
      answer = ask("#{question} (#{default ? 'Y/n' : 'y/N'})").downcase
      answer.empty? ? default : answer.start_with?("y")
    end
  end
end
