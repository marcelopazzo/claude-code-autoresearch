# frozen_string_literal: true

require "json"

module Autoresearch
  # State reconstruction + mutation. Source of truth is autoresearch.jsonl:
  # one JSON object per line, config headers interleaved with result records.
  # A new config header starts a new segment; confidence and baselines are
  # computed within the current (highest) segment only.
  class State
    STATUS_VALUES = %w[keep discard crash checks_failed].freeze

    attr_reader :results
    attr_accessor :name, :metric_name, :metric_unit, :best_direction,
                  :secondary_metrics, :current_segment, :max_experiments

    def initialize
      @results            = []
      @name               = nil
      @metric_name        = ""
      @metric_unit        = ""
      @best_direction     = "lower"
      @secondary_metrics  = []
      @current_segment    = 0
      @max_experiments    = nil
    end

    # -----------------------------------------------------------------------
    # Load from jsonl
    # -----------------------------------------------------------------------

    def self.load(jsonl_path)
      state = new
      return state unless File.exist?(jsonl_path)

      File.readlines(jsonl_path, chomp: true).each do |line|
        next if line.strip.empty?

        begin
          entry = JSON.parse(line)
        rescue JSON::ParserError
          next
        end

        if entry["type"] == "config"
          state.apply_config(entry)
        else
          state.apply_result(entry)
        end
      end
      state
    end

    def apply_config(entry)
      # Each config header starts a new segment, except the very first one.
      @current_segment += 1 unless @results.empty? && @name.nil?
      @current_segment = 0 if @name.nil?

      @name           = entry["name"]
      @metric_name    = entry["metricName"].to_s
      @metric_unit    = entry["metricUnit"].to_s
      @best_direction = entry["bestDirection"] == "higher" ? "higher" : "lower"
      @secondary_metrics = []
    end

    def apply_result(entry)
      return unless entry["commit"]

      @results << entry
      track_secondary_metrics(entry["metrics"])
    end

    def track_secondary_metrics(metrics)
      return unless metrics.is_a?(Hash)

      metrics.each_key do |name|
        next if name == @metric_name
        next if @secondary_metrics.any? { |m| m["name"] == name }

        @secondary_metrics << { "name" => name, "unit" => "" }
      end
    end

    # -----------------------------------------------------------------------
    # Queries
    # -----------------------------------------------------------------------

    def current_segment_results
      @results.select { |r| (r["segment"] || 0) == @current_segment }
    end

    def baseline_metric
      current_segment_results.first&.dig("metric")
    end

    def best_metric
      values = current_segment_results.map { |r| r["metric"] }.compact
      return nil if values.empty?

      @best_direction == "higher" ? values.max : values.min
    end

    def iterations_in_segment
      current_segment_results.length
    end

    def at_iteration_limit?
      return false if @max_experiments.nil?

      iterations_in_segment >= @max_experiments
    end

    def confidence
      values = current_segment_results.map { |r| r["metric"] }.compact
      baseline = baseline_metric
      Confidence.compute(
        values: values,
        baseline: baseline,
        direction: @best_direction.to_sym
      )
    end

    # -----------------------------------------------------------------------
    # Persistence
    # -----------------------------------------------------------------------

    def write_config_header!(jsonl_path)
      header = {
        "type" => "config",
        "name" => @name,
        "metricName" => @metric_name,
        "metricUnit" => @metric_unit,
        "bestDirection" => @best_direction
      }
      append_line(jsonl_path, header)
    end

    def append_result!(jsonl_path, result)
      append_line(jsonl_path, result)
      apply_result(result)
    end

    private

    def append_line(jsonl_path, entry)
      File.open(jsonl_path, "a") do |f|
        f.puts(JSON.generate(entry))
      end
    end
  end
end
