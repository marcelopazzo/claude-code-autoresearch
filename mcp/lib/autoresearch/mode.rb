# frozen_string_literal: true

module Autoresearch
  # Persisted flag indicating autoresearch mode is active.
  # File lives in the working directory so it's scoped to the project
  # (and survives restarts), not a CC session.
  module Mode
    module_function

    def on?
      File.exist?(Paths.mode_path)
    end

    def enable!
      FileUtils.mkdir_p(File.dirname(Paths.mode_path))
      File.write(Paths.mode_path, Time.now.utc.iso8601 + "\n")
    end

    def disable!
      File.delete(Paths.mode_path) if File.exist?(Paths.mode_path)
    end
  end
end

require "fileutils"
require "time"
