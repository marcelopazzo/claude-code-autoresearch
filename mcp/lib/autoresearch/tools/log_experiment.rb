# frozen_string_literal: true

require "mcp"
require_relative "../../autoresearch"

module Autoresearch
  module Tools
    # log_experiment — records a result, optionally auto-commits/auto-reverts,
    # updates the confidence score, and appends to autoresearch.jsonl.
    # Status behavior:
    #   keep           — code is already committed by the agent; append a result row
    #   discard        — revert code changes (git checkout -- .), log result
    #   crash          — same as discard, different status for analytics
    #   checks_failed  — same as discard
    class LogExperiment < MCP::Tool
      tool_name "log_experiment"
      description <<~DESC
        Record an experiment result. Appends to autoresearch.jsonl. Status:
        - keep: the improvement is real, the commit stands
        - discard: revert code changes (autoresearch.* files are preserved)
        - crash: runtime/compile error; revert like discard
        - checks_failed: benchmark passed but autoresearch.checks.sh failed; revert
        Always include a secondary `metrics` dict. Use `asi` to annotate the run
        with anything that would help the next iteration make a better decision.
      DESC
      input_schema(
        properties: {
          commit: {
            type: "string",
            description: "Short git commit hash (7 chars) of the change being logged"
          },
          metric: {
            type: "number",
            description: "Primary optimization metric value. 0 for crashes."
          },
          status: {
            type: "string",
            enum: %w[keep discard crash checks_failed]
          },
          description: {
            type: "string",
            description: "Short human-readable summary of what this experiment tried"
          },
          metrics: {
            type: "object",
            description: "Secondary metrics: { name: number }",
            additionalProperties: { type: "number" }
          },
          asi: {
            type: "object",
            description: "Actionable Side Information — free-form diagnostics for the next iteration",
            additionalProperties: true
          },
          force: {
            type: "boolean",
            description: "If true, skip the checks_failed guard that normally blocks keep"
          }
        },
        required: %w[commit metric status description]
      )

      class << self
        def call(commit:, metric:, status:, description:,
                 metrics: {}, asi: {}, force: false, server_context: nil)
          work_dir = Paths.work_dir
          unless File.directory?(work_dir)
            return error("Working directory does not exist: #{work_dir}")
          end

          unless State::STATUS_VALUES.include?(status)
            return error("Invalid status: #{status}")
          end

          state = State.load(Paths.jsonl_path)

          if status == "keep" && !force && last_checks_failed?(state)
            return error("Cannot keep — previous run's checks failed. Re-run or pass force=true.")
          end

          maybe_revert_code(work_dir: work_dir, status: status)

          result_entry = {
            "commit" => commit,
            "metric" => Float(metric),
            "metrics" => (metrics || {}).transform_values { |v| Float(v) },
            "status" => status,
            "description" => description,
            "timestamp" => Time.now.to_i,
            "segment" => state.current_segment,
            "asi" => asi || {}
          }

          state.append_result!(Paths.jsonl_path, result_entry)
          confidence = state.confidence

          text = format_summary(state: state, entry: result_entry, confidence: confidence)

          MCP::Tool::Response.new(
            [{ type: "text", text: text }],
            structured_content: {
              confidence: confidence,
              best_metric: state.best_metric,
              baseline_metric: state.baseline_metric,
              iterations_in_segment: state.iterations_in_segment,
              at_iteration_limit: state.at_iteration_limit?
            }
          )
        end

        private

        def last_checks_failed?(state)
          last = state.current_segment_results.last
          last && last["status"] == "checks_failed"
        end

        # Revert uncommitted changes except session files (autoresearch.*).
        # The session files track state across iterations and MUST survive reverts.
        # We use pathspec magic `:(exclude)` to scope git's operations.
        def maybe_revert_code(work_dir:, status:)
          return if status == "keep"

          Dir.chdir(work_dir) do
            # Throw away modifications to tracked files, except session files.
            system("git", "checkout", "--",
                   ":(exclude)autoresearch.*", ".",
                   out: File::NULL, err: File::NULL)
            # Remove untracked files the experiment added, but not session files.
            system("git", "clean", "-fd", "-e", "autoresearch.*",
                   out: File::NULL, err: File::NULL)
          end
        end

        def format_summary(state:, entry:, confidence:)
          lines = []
          lines << "Logged: #{entry["status"]} — #{entry["description"]}"
          lines << "Primary #{state.metric_name}: #{entry["metric"]} (baseline #{state.baseline_metric}, best #{state.best_metric})"
          lines << "Iteration #{state.iterations_in_segment} of segment #{state.current_segment}"

          if confidence
            marker = confidence >= 2.0 ? "🟢" : confidence >= 1.0 ? "🟡" : "🔴"
            lines << "Confidence: #{marker} #{confidence.round(2)}× noise floor"
          else
            lines << "Confidence: not enough data yet (need 3+ runs in this segment)"
          end

          if state.at_iteration_limit?
            lines << "⚠️  Reached maxIterations (#{state.max_experiments}). Stop looping or re-init."
          end

          lines.join("\n")
        end

        def error(message)
          MCP::Tool::Response.new([{ type: "text", text: "❌ #{message}" }], error: true)
        end
      end
    end
  end
end
