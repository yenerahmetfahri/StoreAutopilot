module StoreAutopilot
  # The result of a release/submit/rollout on the GitHub Actions run page (the job summary): outcome, each step with
  # its duration, and warnings. Does nothing outside GitHub Actions.
  module Summary
    module_function

    # steps: [[title, started_at], ...] in order; finished_at closes the last one.
    def write(title:, ok:, detail: nil, hint: nil, steps: [], warnings: [], finished_at: Time.now, path: ENV["GITHUB_STEP_SUMMARY"])
      return if path.to_s.empty?
      lines = ["### #{ok ? '✅' : '❌'} #{title}", ""]
      lines += [detail.to_s, ""] if detail
      lines += ["→ #{hint}", ""] if hint
      if steps.any?
        lines += ["| Step | Time |", "|---|---|"]
        steps.each_with_index do |(name, started), i|
          ended = steps[i + 1]&.last || finished_at
          lines << "| #{name.gsub('|', '\\|')} | #{clock(ended - started)} |"
        end
        lines << ""
      end
      lines += ["**Warnings**", "", *warnings.map { |w| "- #{w}" }, ""] if warnings.any?
      File.open(path, "a") { |f| f.puts(lines) }
    rescue SystemCallError
      nil # a summary is a nicety; never fail a release over it
    end

    def clock(seconds)
      seconds = seconds.round
      format("%d:%02d", seconds / 60, seconds % 60)
    end
  end
end
