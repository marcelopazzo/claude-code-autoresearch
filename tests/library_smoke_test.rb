#!/usr/bin/env ruby
# frozen_string_literal: true

# Smoke test for the Autoresearch Ruby library. Exercises the pieces
# that don't require a running MCP server: metric parsing, confidence,
# state round-trip, and the runner timeout.
#
# Run with: ruby tests/library_smoke_test.rb

require "bundler/setup"
require "fileutils"
require "tmpdir"

$LOAD_PATH.unshift File.expand_path("../mcp/lib", __dir__)
require "autoresearch"

def assert(cond, msg)
  unless cond
    warn "✗ #{msg}"
    exit 1
  end
  puts "✓ #{msg}"
end

# ---------------------------------------------------------------------------
# Metrics.parse_lines
# ---------------------------------------------------------------------------
parsed = Autoresearch::Metrics.parse_lines(<<~OUT)
  starting...
  METRIC total_seconds=42.3
  METRIC failures=0
  METRIC total_seconds=41.1
  done
OUT
assert parsed == { "total_seconds" => 41.1, "failures" => 0.0 },
       "Metrics.parse_lines keeps the last value and parses multiple names"

# Reject prototype-pollution names
parsed = Autoresearch::Metrics.parse_lines("METRIC __proto__=99\nMETRIC ok=1\n")
assert parsed == { "ok" => 1.0 }, "Metrics.parse_lines ignores dangerous names"

# ---------------------------------------------------------------------------
# Confidence.compute
# ---------------------------------------------------------------------------
conf = Autoresearch::Confidence.compute(
  values: [100.0, 99.5, 98.0, 75.0, 99.0], baseline: 100.0, direction: :lower
)
assert conf && conf > 10, "Confidence: clear improvement scores above noise floor"

conf_noisy = Autoresearch::Confidence.compute(
  values: [100.0, 110.0, 90.0, 101.0], baseline: 100.0, direction: :lower
)
conf_clear = Autoresearch::Confidence.compute(
  values: [100.0, 99.5, 98.0, 75.0, 99.0], baseline: 100.0, direction: :lower
)
assert conf_clear && conf_noisy && conf_clear > conf_noisy,
       "Confidence: clear outlier improvements rank above noisy sessions"

conf = Autoresearch::Confidence.compute(values: [100.0, 100.0], baseline: 100.0, direction: :lower)
assert conf.nil?, "Confidence: under 3 values returns nil"

conf = Autoresearch::Confidence.compute(values: [100.0, 100.0, 100.0], baseline: 100.0, direction: :lower)
assert conf.nil?, "Confidence: zero improvement returns nil"

# ---------------------------------------------------------------------------
# State round-trip via jsonl
# ---------------------------------------------------------------------------
Dir.mktmpdir do |tmp|
  ENV["CLAUDE_PROJECT_DIR"] = tmp
  jsonl = File.join(tmp, "autoresearch.jsonl")

  state = Autoresearch::State.new
  state.name = "test"
  state.metric_name = "ms"
  state.metric_unit = "ms"
  state.best_direction = "lower"
  state.write_config_header!(jsonl)

  state.append_result!(jsonl, {
    "commit" => "aaaaaaa", "metric" => 100.0, "metrics" => {},
    "status" => "keep", "description" => "baseline",
    "timestamp" => Time.now.to_i, "segment" => 0, "asi" => {}
  })
  state.append_result!(jsonl, {
    "commit" => "bbbbbbb", "metric" => 90.0, "metrics" => {},
    "status" => "keep", "description" => "improvement",
    "timestamp" => Time.now.to_i, "segment" => 0, "asi" => {}
  })

  reloaded = Autoresearch::State.load(jsonl)
  assert reloaded.results.length == 2, "State: reloads both appended results"
  assert reloaded.metric_name == "ms", "State: config header survives round-trip"
  assert reloaded.baseline_metric == 100.0, "State: baseline is first result of current segment"
  assert reloaded.best_metric == 90.0, "State: best is the min for lower-is-better"
end

# ---------------------------------------------------------------------------
# Runner: successful run captures output, timeout triggers
# ---------------------------------------------------------------------------
Dir.mktmpdir do |tmp|
  result = Autoresearch::Runner.run(
    command: %(echo 'METRIC total_seconds=1.5' && echo 'done'),
    work_dir: tmp,
    timeout_s: 5
  )
  assert result.exit_code == 0, "Runner: successful command returns exit 0"
  assert result.tail.include?("METRIC total_seconds=1.5"),
         "Runner: tail captures METRIC lines"
  assert !result.timed_out, "Runner: short command doesn't time out"

  timeout_result = Autoresearch::Runner.run(
    command: "sleep 10",
    work_dir: tmp,
    timeout_s: 1
  )
  assert timeout_result.timed_out, "Runner: sleep 10 under 1s timeout triggers timed_out"
end

puts "\nAll checks passed."
