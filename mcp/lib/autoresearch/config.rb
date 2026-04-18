# frozen_string_literal: true

require "json"

module Autoresearch
  module Config
    module_function

    def load(cwd)
      path = File.join(cwd, "autoresearch.config.json")
      return {} unless File.exist?(path)

      JSON.parse(File.read(path))
    rescue JSON::ParserError
      {}
    end

    def max_iterations(cwd)
      value = load(cwd)["maxIterations"]
      return nil unless value.is_a?(Numeric) && value.positive?

      value.to_i
    end
  end
end
