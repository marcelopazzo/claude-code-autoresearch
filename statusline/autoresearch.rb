#!/usr/bin/env ruby
# frozen_string_literal: true

# Statusline script — prints one line describing the autoresearch session,
# mirroring the upstream widget:
#   🔬 autoresearch 12 runs 8 kept │ ★ total_seconds: 15.20 (-12.3%) │ conf: 2.1×
#
# Claude Code invokes this on each refresh; stdin has session info as JSON.

require "json"
require_relative "../mcp/lib/autoresearch"

begin
  input = JSON.parse($stdin.read)
rescue JSON::ParserError
  input = {}
end

ENV["CLAUDE_PROJECT_DIR"] ||= input.dig("workspace", "current_dir") || input["cwd"] || Dir.pwd

exit 0 unless File.exist?(Autoresearch::Paths.jsonl_path)

state = Autoresearch::State.load(Autoresearch::Paths.jsonl_path)
results = state.current_segment_results
exit 0 if results.empty?

total = results.length
kept = results.count { |r| r["status"] == "keep" }
baseline = state.baseline_metric
best = state.best_metric

parts = ["🔬 autoresearch #{total} runs #{kept} kept"]

if baseline && best
  delta = baseline.zero? ? 0.0 : ((best - baseline) / baseline.abs) * 100.0
  sign = delta >= 0 ? "+" : ""
  metric_label = state.metric_name.to_s.empty? ? "metric" : state.metric_name
  parts << "★ #{metric_label}: #{format("%.3g", best)} (#{sign}#{format("%.1f", delta)}%)"
end

conf = state.confidence
if conf
  parts << "conf: #{format("%.1f", conf)}×"
end

parts << "mode:off" unless Autoresearch::Mode.on?

puts parts.join(" │ ")
