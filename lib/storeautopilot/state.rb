require "digest"
require "json"

module StoreAutopilot
  # Remembers what was last uploaded so unchanged text/images are skipped.
  class State
    def self.digest(dir, only: nil, except: nil)
      sha = Digest::SHA256.new
      Dir.glob("**/*", base: dir).sort.each do |rel|
        full = File.join(dir, rel)
        next unless File.file?(full)
        next if only && rel !~ only
        next if except && rel =~ except
        sha << rel << "\0" << File.binread(full) << "\0"
      end
      sha.hexdigest
    end

    def initialize(path)
      @path = path
    end

    def [](key) = data[key]
    def changed?(key, digest) = data[key] != digest

    def record(key, value)
      @data = data.merge(key => value)
      tmp = "#{@path}.tmp"
      File.write(tmp, JSON.pretty_generate(@data))
      File.chmod(0o600, tmp)
      File.rename(tmp, @path)
    end

    private

    def data
      @data ||= File.file?(@path) ? JSON.parse(File.read(@path)) : {}
    rescue JSON::ParserError
      @data = {}
    end
  end
end
