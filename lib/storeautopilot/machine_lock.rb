require "fileutils"
require "json"

module StoreAutopilot
  # One release or screenshot run at a time on this Mac, across all apps: they share the simulators, the emulator and
  # the CPU. A second run waits for the first. The lock is the OS's (flock), so it is released even if a run crashes.
  class MachineLock
    def initialize(home:, app_id:, what:, wait: 2 * 60 * 60, poll: 10)
      @path = File.join(home, ".storeautopilot", "machine.lock")
      @app_id = app_id
      @what = what
      @wait = wait
      @poll = poll
    end

    def hold
      FileUtils.mkdir_p(File.dirname(@path))
      File.open(@path, File::RDWR | File::CREAT, 0o600) do |file|
        acquire(file)
        file.truncate(0)
        file.write(JSON.generate(app: @app_id, what: @what, pid: Process.pid, since: Time.now.strftime("%H:%M")))
        file.flush
        yield
      ensure
        file.flock(File::LOCK_UN)
      end
    end

    private

    def acquire(file)
      return if file.flock(File::LOCK_EX | File::LOCK_NB)
      holder = begin
        JSON.parse(File.read(@path))
      rescue JSON::ParserError
        {}
      end
      UI.step("Waiting: this Mac is busy with #{holder['app'] || 'another app'}'s #{holder['what'] || 'run'} " \
              "(since #{holder['since'] || '?'}); one store run at a time keeps simulators from clashing")
      deadline = Time.now + @wait
      until file.flock(File::LOCK_EX | File::LOCK_NB)
        if Time.now > deadline
          raise Error.new("Gave up after waiting #{@wait / 60} minutes for #{holder['app'] || 'another app'} to finish.",
                          hint: "If nothing is running, the lock is free again once that process has ended.")
        end
        sleep(@poll)
      end
      UI.ok("the Mac is free; continuing")
    end
  end
end
