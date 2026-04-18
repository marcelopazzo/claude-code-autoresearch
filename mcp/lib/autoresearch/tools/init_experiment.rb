# frozen_string_literal: true

require "mcp"
require_relative "../../autoresearch"

module Autoresearch
  module Tools
    class InitExperiment < MCP::Tool
      tool_name "init_experiment"
      description <<~DESC
        Initialize the experiment session. Call once before the first run_experiment
        to set the name, primary metric, unit, and direction. Writes the config
        header to autoresearch.jsonl. Call again to start a new segment with a new
        baseline when the optimization target changes.
      DESC
      input_schema(
        properties: {
          name: {
            type: "string",
            description: 'Human-readable name (e.g. "Rails test suite speedup")'
          },
          metric_name: {
            type: "string",
            description: 'Display name for the primary metric (e.g. "total_seconds", "bundle_kb")'
          },
          metric_unit: {
            type: "string",
            description: 'Unit for the primary metric. Use "µs", "ms", "s", "kb", "mb", or "" for unitless.'
          },
          direction: {
            type: "string",
            enum: %w[lower higher],
            description: 'Whether "lower" or "higher" is better. Default: "lower".'
          }
        },
        required: %w[name metric_name]
      )

      class << self
        def call(name:, metric_name:, metric_unit: "", direction: "lower", server_context: nil)
          work_dir = Paths.work_dir
          unless File.directory?(work_dir)
            return error("Working directory does not exist: #{work_dir}")
          end

          state = State.load(Paths.jsonl_path)
          is_reinit = !state.results.empty?

          state.name = name
          state.metric_name = metric_name
          state.metric_unit = metric_unit.to_s
          state.best_direction = direction == "higher" ? "higher" : "lower"
          state.current_segment += 1 if is_reinit
          state.max_experiments = Config.max_iterations(Paths.session_cwd)

          state.write_config_header!(Paths.jsonl_path)
          Mode.enable!

          reinit_note = is_reinit ? " (re-initialized — new segment, new baseline needed)" : ""
          limit_note = state.max_experiments ? "\nMax iterations: #{state.max_experiments}" : ""
          workdir_note = work_dir == Paths.session_cwd ? "" : "\nWorking directory: #{work_dir}"

          text = <<~TEXT
            ✅ Experiment initialized: "#{state.name}"#{reinit_note}
            Metric: #{state.metric_name} (#{state.metric_unit.empty? ? "unitless" : state.metric_unit}, #{state.best_direction} is better)#{limit_note}#{workdir_note}
            Config written to autoresearch.jsonl. Now run the baseline with run_experiment.
          TEXT

          MCP::Tool::Response.new([{ type: "text", text: text.strip }])
        end

        private

        def error(message)
          MCP::Tool::Response.new([{ type: "text", text: "❌ #{message}" }], error: true)
        end
      end
    end
  end
end
