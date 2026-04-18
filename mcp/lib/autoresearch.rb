# frozen_string_literal: true

module Autoresearch
  VERSION = "0.1.0"

  SESSION_FILE_PREFIX = "autoresearch."

  def self.session_file?(path)
    File.basename(path.to_s).start_with?(SESSION_FILE_PREFIX)
  end
end

require_relative "autoresearch/paths"
require_relative "autoresearch/config"
require_relative "autoresearch/metrics"
require_relative "autoresearch/confidence"
require_relative "autoresearch/state"
require_relative "autoresearch/runner"
require_relative "autoresearch/mode"
