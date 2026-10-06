require "fileutils"

module StoreAutopilot
  module UI
    KEEP_LOGS = 30

    class << self
      attr_writer :out, :notifications
      attr_reader :log_path

      # Steps and warnings shown so far, for summaries: [[title, time], ...] and [message, ...].
      def steps = (@steps ||= [])
      def warnings = (@warnings ||= [])

      def out = @out || $stdout
      def step(title)
        steps << [title, Time.now]
        out.puts("\n▶ #{title}")
        @log&.puts("\n▶ #{title}  [#{Time.now.strftime('%H:%M:%S')}]")
      end

      def info(msg) = say("  #{msg}")
      def ok(msg) = say("  ✓ #{msg}")
      def warn(msg)
        warnings << msg
        say("  ! #{msg}")
      end
      def bad(msg) = say("  ✗ #{msg}")

      def error(err)
        say("\n✗ #{err.message}")
        say("  → #{err.hint}") if err.respond_to?(:hint) && err.hint
        say("  Log: #{log_path}") if log_path
      end

      # Output of a child process, passed through as-is.
      def output(text)
        out.print(text)
        @log&.print(text)
      end

      # Full details (e.g. a backtrace) that belong in the log file but not on screen.
      def log_only(text) = @log&.puts(text)

      # Mirrors everything shown on screen (and child process output) into a new, private log file in dir.
      def start_log(dir, name)
        FileUtils.mkdir_p(dir)
        File.chmod(0o700, dir)
        old = Dir.glob(File.join(dir, "*.log")).sort
        FileUtils.rm_f(old.first(old.size - KEEP_LOGS + 1)) if old.size >= KEEP_LOGS
        @log_path = File.join(dir, "#{Time.now.strftime("%Y%m%d-%H%M%S")}-#{name}-#{Process.pid}.log")
        @log = File.open(@log_path, "a", 0o600)
        @log.sync = true
        @log.puts("StoreAutopilot #{name} — #{Time.now} — ruby #{RUBY_VERSION}")
      rescue SystemCallError => e
        @log = @log_path = nil
        warn("could not write a log file in #{dir}: #{e.message}")
      end

      def close_log
        @log&.close
        @log = @log_path = nil
      end

      # macOS notification; message passed as an argument, never interpolated into the script.
      def notify(msg)
        return if @notifications == false
        system("osascript", "-e", "on run argv", "-e", "display notification (item 1 of argv) with title \"StoreAutopilot\"",
               "-e", "end run", msg, out: File::NULL, err: File::NULL)
      end

      private

      def say(text)
        out.puts(text)
        @log&.puts(text)
      end
    end
  end
end
