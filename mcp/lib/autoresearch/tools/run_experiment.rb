# frozen_string_literal: true

require "mcp"
require "open3"
require_relative "../../autoresearch"

module Autoresearch
  module Tools
    # run_experiment — executes a command, times it, parses METRIC lines,
    # and (when autoresearch.checks.sh exists) runs correctness checks
    # after a passing benchmark. Returns a text summary plus structured
    # details the agent feeds back into log_experiment.
    class RunExperiment < MCP::Tool
      tool_name "run_experiment"
      description <<~DESC
        Run a benchmark command. Times wall-clock duration, captures the tail
        of stdout/stderr, and parses `METRIC name=value` lines into a primary
        metric + secondary metrics. If `autoresearch.checks.sh` exists and the
        benchmark exits 0, runs checks and reports pass/fail. Always call
        log_experiment after this returns.
      DESC
      input_schema(
        properties: {
          command: {
            type: "string",
            description: "Shell command (e.g. './autoresearch.sh', 'bundle exec rake test')"
          },
          timeout_seconds: {
            type: "number",
            description: "Kill after this many seconds (default: 600)"
          },
          checks_timeout_seconds: {
            type: "number",
            description: "Timeout for autoresearch.checks.sh (default: 300). Ignored if the file doesn't exist."
          }
        },
        required: %w[command]
      )

      class << self
        def call(command:, timeout_seconds: 600, checks_timeout_seconds: 300, server_context: nil)
          work_dir = Paths.work_dir
          unless File.directory?(work_dir)
            return error("Working directory does not exist: #{work_dir}")
          end

          state = State.load(Paths.jsonl_path)
          capture_pre_run_head(work_dir)

          result = Runner.run(
            command: command,
            work_dir: work_dir,
            timeout_s: Integer(timeout_seconds)
          )

          parsed = Metrics.parse_lines(result.full_output)
          primary = state.metric_name.empty? ? nil : parsed[state.metric_name]
          passed = result.exit_code == 0 && !result.timed_out

          checks_result = maybe_run_checks(
            passed: passed,
            work_dir: work_dir,
            timeout_s: Integer(checks_timeout_seconds)
          )

          text = format_summary(
            command: command,
            result: result,
            passed: passed,
            primary: primary,
            parsed: parsed,
            metric_name: state.metric_name,
            metric_unit: state.metric_unit,
            checks: checks_result
          )

          MCP::Tool::Response.new(
            [{ type: "text", text: text }],
            structured_content: {
              exit_code: result.exit_code,
              duration_s: result.duration_s,
              timed_out: result.timed_out,
              passed: passed,
              parsed_metrics: parsed,
              primary_metric: primary,
              output_tail: result.tail,
              checks_pass: checks_result&.[](:pass),
              checks_timed_out: checks_result&.[](:timed_out) || false,
              checks_tail: checks_result&.[](:tail)
            }
          )
        end

        private

        # Snapshot HEAD so log_experiment can revert any commits the agent
        # makes between run_experiment and log_experiment when the result
        # is discarded. Silent no-op when not in a git repo.
        def capture_pre_run_head(work_dir)
          head, status = Open3.capture2e("git", "rev-parse", "HEAD", chdir: work_dir)
          return unless status.success?

          File.write(Paths.pre_run_path, head.strip + "\n")
        rescue StandardError
          # If we can't capture, the discard path falls back to the old
          # working-tree-only revert — never block the run on this.
        end

        def maybe_run_checks(passed:, work_dir:, timeout_s:)
          return nil unless passed
          return nil unless File.exist?(Paths.checks_path)

          result = Runner.run(
            command: "bash #{Paths.checks_path}",
            work_dir: work_dir,
            timeout_s: timeout_s
          )
          {
            pass: result.exit_code == 0 && !result.timed_out,
            timed_out: result.timed_out,
            duration_s: result.duration_s,
            tail: result.tail
          }
        end

        def format_summary(command:, result:, passed:, primary:, parsed:, metric_name:, metric_unit:, checks:)
          lines = []
          header = if result.timed_out
                     "⏱️  Timed out after #{result.duration_s.round(1)}s"
                   elsif passed
                     "✅ exit=0 in #{result.duration_s.round(2)}s"
                   else
                     "❌ exit=#{result.exit_code.inspect} in #{result.duration_s.round(2)}s"
                   end
          lines << header
          lines << "Command: #{command}"

          if primary && !metric_name.empty?
            unit = metric_unit.empty? ? "" : " #{metric_unit}"
            lines << "Primary metric #{metric_name}: #{primary}#{unit}"
          elsif !metric_name.empty?
            lines << "⚠️  No METRIC line matched #{metric_name}"
          end

          if parsed.any?
            others = parsed.reject { |k, _| k == metric_name }
            unless others.empty?
              lines << "Other metrics: " + others.map { |k, v| "#{k}=#{v}" }.join(", ")
            end
          end

          if checks
            if checks[:pass]
              lines << "✅ Checks passed in #{checks[:duration_s].round(2)}s"
            elsif checks[:timed_out]
              lines << "⏱️  Checks timed out — log as checks_failed"
            else
              lines << "❌ Checks failed — log as checks_failed"
              lines << "--- checks tail ---"
              lines << checks[:tail].to_s
            end
          end

          lines << "--- output tail ---"
          lines << result.tail.to_s
          lines.join("\n")
        end

        def error(message)
          MCP::Tool::Response.new([{ type: "text", text: "❌ #{message}" }], error: true)
        end
      end
    end
  end
end
