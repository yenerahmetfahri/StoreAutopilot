module StoreAutopilot
  # Machine-level tool locations, with the defaults Android Studio / Homebrew use on macOS.
  module Env
    STUDIO_JBR = "/Applications/Android Studio.app/Contents/jbr/Contents/Home"

    def self.android_home = ENV["ANDROID_HOME"] || ENV["ANDROID_SDK_ROOT"] || File.join(Dir.home, "Library/Android/sdk")
    def self.sdk_tool(rel) = File.join(android_home, rel)
    def self.java_home = ENV["JAVA_HOME"].to_s.empty? ? STUDIO_JBR : ENV["JAVA_HOME"]
    def self.keytool = File.join(java_home, "bin", "keytool")

    # Environment for every child process.
    def self.tools
      {
        "ANDROID_HOME" => android_home,
        "JAVA_HOME" => java_home,
        "LANG" => "en_US.UTF-8",
        "LC_ALL" => "en_US.UTF-8",
        "FASTLANE_SKIP_UPDATE_CHECK" => "1",
        "FASTLANE_HIDE_CHANGELOG" => "1",
        "FASTLANE_OPT_OUT_USAGE" => "1"
      }
    end
  end
end
