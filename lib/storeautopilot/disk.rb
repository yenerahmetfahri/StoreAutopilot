module StoreAutopilot
  # Free space on the disk that builds, simulators and caches live on. A release needs several GB (iOS archive, app
  # bundle, simulator data); running out shows up much later as an unrelated-looking Gradle or Xcode error.
  module Disk
    MIN_GB = 5
    COMFORTABLE_GB = 15
    HINT = "Free up space, e.g. Xcode's DerivedData (~/Library/Developer/Xcode/DerivedData), unused simulators " \
           "(`xcrun simctl delete unavailable`) or old Gradle caches (~/.gradle/caches)."

    # GB free at path, or nil if it can't be read.
    def self.free_gb(shell, path)
      kb = shell.capture("df", "-Pk", path, allow_failure: true).lines[1]&.split&.at(3)
      kb && kb.to_i / 1024.0 / 1024
    end

    def self.check!(shell, path)
      free = free_gb(shell, path)
      return unless free && free < MIN_GB
      raise Error.new("Only #{free.round(1)} GB free on this Mac's disk; a release needs at least #{MIN_GB} GB.", hint: HINT)
    end
  end
end
