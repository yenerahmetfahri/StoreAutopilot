require "json"
require "fileutils"

module StoreAutopilot
  # Hands a lane its data through a private JSON file (paths only, never key contents).
  class Fastlane
    def initialize(shell:, workdir:, retry_delay: 30)
      @shell = shell
      @workdir = workdir
      @retry_delay = retry_delay
    end

    # quiet: keep fastlane's output out of the terminal (it still goes to the log).
    # retries: run again after a failure or an {"error": …} result, for lanes that are safe to repeat (they read, or
    # write the same data again) — never for uploads of a new build. Store APIs fail now and then for no lasting reason.
    def lane(platform, name, job, quiet: false, retries: 0)
      (retries + 1).times do |attempt|
        last = attempt == retries
        begin
          result = run_lane(platform, name, job, quiet)
          return result if last || !result["error"]
          reason = result["error"]
        rescue Error => e
          raise if last
          reason = e.message
        end
        UI.warn("fastlane #{platform} #{name}: #{reason.lines.first.to_s.strip} — trying again in #{@retry_delay}s")
        sleep(@retry_delay)
      end
    end

    private

    def run_lane(platform, name, job, quiet)
      FileUtils.mkdir_p(@workdir)
      File.chmod(0o700, @workdir)
      job_path = File.join(@workdir, "job.json")
      out_path = File.join(@workdir, "lane_output.json")
      FileUtils.rm_f(out_path)
      File.write(job_path, JSON.generate(job.merge(output: out_path)))
      File.chmod(0o600, job_path)
      cmd = ["fastlane", platform.to_s, name.to_s]
      env = { "STOREAUTOPILOT_JOB" => job_path }
      if quiet
        UI.log_only(@shell.capture(*cmd, chdir: ROOT, env: env, allow_failure: true))
        raise Error.new("fastlane #{platform} #{name} failed.", hint: "Its output is in the log.") unless File.file?(out_path)
      else
        @shell.run(*cmd, chdir: ROOT, env: env)
      end
      File.file?(out_path) ? JSON.parse(File.read(out_path)) : {}
    rescue JSON::ParserError
      raise Error.new("fastlane #{platform} #{name} wrote an unreadable result to #{out_path}")
    end
  end
end
