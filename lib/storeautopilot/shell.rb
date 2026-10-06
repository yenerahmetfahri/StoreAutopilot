require "open3"

module StoreAutopilot
  # The only place external commands are executed. Never echoes arguments (they may contain tokens).
  class Shell
    # A command that prints nothing for this long is taken to be stuck (e.g. an app frozen in its screenshot test).
    IDLE_TIMEOUT = 30 * 60

    def initialize(env: {}, idle_timeout: IDLE_TIMEOUT)
      @env = env
      @idle_timeout = idle_timeout
    end

    # Streams output to the terminal and the log; raises Error on non-zero exit, or when the command stays silent for
    # idle_timeout seconds. stdin is closed, so a tool that unexpectedly asks a question fails at once instead of
    # hanging an unattended run.
    def run(*cmd, chdir: nil, env: {})
      opts = { pgroup: true } # own process group, so a stuck command can be stopped with everything it started
      opts[:chdir] = chdir if chdir
      status = Open3.popen2e(@env.merge(env), *cmd, **opts) do |stdin, out, wait|
        stdin.close
        last_output = Time.now
        reader = Thread.new { out.each_line { |line| last_output = Time.now; UI.output(line.scrub) } }
        begin
          until wait.join(1)
            next if Time.now - last_output < @idle_timeout
            stop(wait)
            raise Error.new("No output for #{duration(@idle_timeout)}, stopped: #{label(cmd)}",
                            hint: "It looked stuck; the log shows the last thing it did.")
          end
        rescue Interrupt
          stop(wait)
          raise
        end
        reader.join
        wait.value
      end
      return true if status.success?
      raise Error.new("Command failed (#{exit_reason(status)}): #{label(cmd)}", hint: "See the output above.")
    rescue Errno::ENOENT, Errno::EACCES => e
      raise Error.new("Could not start #{label(cmd)}: #{e.message}", hint: "Run `storeautopilot doctor` to check installed tools.")
    end

    # Returns stdout. Raises Error on failure unless allow_failure; kills the command after `timeout` seconds.
    def capture(*cmd, chdir: nil, env: {}, allow_failure: false, timeout: nil)
      opts = { pgroup: true }
      opts[:chdir] = chdir if chdir
      out, err, status = Open3.popen3(@env.merge(env), *cmd, **opts) do |stdin, stdout, stderr, wait|
        stdin.close
        readers = [stdout, stderr].map { |io| Thread.new { io.read }.tap { |t| t.report_on_exception = false } }
        unless wait.join(timeout)
          Process.kill("KILL", -wait.pid) rescue nil
          wait.join
          readers.each { |t| t.join(5) rescue nil }
          raise Error.new("Command timed out after #{timeout}s: #{label(cmd)}")
        end
        [readers[0].value, readers[1].value, wait.value]
      end
      return out if status.success? || allow_failure
      UI.log_only("#{label(cmd)} failed (#{exit_reason(status)}):\n#{err}") unless err.strip.empty?
      raise Error.new("Command failed (#{exit_reason(status)}): #{label(cmd)}", hint: err.strip.lines.last&.strip)
    rescue Errno::ENOENT, Errno::EACCES => e
      raise Error.new("Could not start #{label(cmd)}: #{e.message}", hint: "Run `storeautopilot doctor` to check installed tools.")
    end

    # Starts a long-running process detached from us (e.g. an emulator).
    def spawn_bg(*cmd)
      pid = Process.spawn(@env, *cmd, out: File::NULL, err: File::NULL, pgroup: true)
      Process.detach(pid)
      pid
    end

    def available?(name)
      path = @env["PATH"] || ENV["PATH"].to_s
      path.split(File::PATH_SEPARATOR).any? { |d| File.executable?(File.join(d, name)) }
    end

    private

    # Program name and its first two arguments only: later ones may be tokens or paths.
    def label(cmd) = [File.basename(cmd.first.to_s), *cmd[1, 2]].join(" ")

    def stop(wait)
      Process.kill("TERM", -wait.pid)
      Process.kill("KILL", -wait.pid) unless wait.join(10)
    rescue Errno::ESRCH
      nil
    end

    def duration(seconds) = seconds >= 60 ? "#{seconds / 60} min" : "#{seconds}s"

    def exit_reason(status) = status.signaled? ? "killed by signal #{status.termsig}" : "exit #{status.exitstatus}"
  end
end
