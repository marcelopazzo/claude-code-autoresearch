# frozen_string_literal: true

module Autoresearch
  module Metrics
    PREFIX = "METRIC"
    DENIED_NAMES = %w[__proto__ constructor prototype].freeze

    module_function

    # Parse `METRIC name=value` lines from stdout/stderr.
    # Later occurrences of the same name overwrite earlier ones.
    def parse_lines(output)
      result = {}
      output.to_s.each_line do |line|
        stripped = line.strip
        next unless stripped.start_with?("#{PREFIX} ")

        body = stripped[PREFIX.length + 1..].to_s
        name, _, value = body.partition("=")
        name = name.strip
        value = value.strip

        next if name.empty? || value.empty?
        next if DENIED_NAMES.include?(name)

        begin
          result[name] = Float(value)
        rescue ArgumentError, TypeError
          next
        end
      end
      result
    end
  end
end
