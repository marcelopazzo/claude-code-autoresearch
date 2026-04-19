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

# ---------------------------------------------------------------------------
# Runner.sanitize: strips ANSI/control chars so JSON-RPC stays serializable
# ---------------------------------------------------------------------------
sanitized = Autoresearch::Runner.sanitize("\e[31mred\e[0m and \e[1;32mgreen\e[m\n")
assert sanitized == "red and green\n",
       "sanitize: strips ANSI CSI color codes"

sanitized = Autoresearch::Runner.sanitize("progress 10%\rprogress 50%\rdone\n")
assert sanitized == "progress 10%\nprogress 50%\ndone\n",
       "sanitize: converts bare carriage returns to newlines"

sanitized = Autoresearch::Runner.sanitize("title\e]0;new title\abody\n")
assert sanitized == "titlebody\n",
       "sanitize: strips OSC escape sequences"

sanitized = Autoresearch::Runner.sanitize("bell\aok\n")
assert sanitized == "bellok\n",
       "sanitize: strips C0 control chars but keeps \\t and \\n"

sanitized = Autoresearch::Runner.sanitize("tab\there\nline\n")
assert sanitized == "tab\there\nline\n",
       "sanitize: preserves tabs and newlines"

# ---------------------------------------------------------------------------
# Runner: scrubs Bundler envvars so user scripts get a clean Ruby env
# ---------------------------------------------------------------------------
Dir.mktmpdir do |tmp|
  ENV["BUNDLE_GEMFILE"] = "/some/parent/Gemfile"
  ENV["RUBYOPT"]        = "-rfoo"
  ENV["GEM_HOME"]       = "/parent/gems"

  result = Autoresearch::Runner.run(
    command: %(echo "BG=${BUNDLE_GEMFILE:-unset}" && echo "RO=${RUBYOPT:-unset}" && echo "GH=${GEM_HOME:-unset}"),
    work_dir: tmp,
    timeout_s: 5
  )
  assert result.tail.include?("BG=unset"), "Runner: scrubs BUNDLE_GEMFILE from spawn env"
  assert result.tail.include?("RO=unset"), "Runner: scrubs RUBYOPT from spawn env"
  assert result.tail.include?("GH=unset"), "Runner: scrubs GEM_HOME from spawn env"
ensure
  ENV.delete("BUNDLE_GEMFILE")
  ENV.delete("RUBYOPT")
  ENV.delete("GEM_HOME")
end

# ---------------------------------------------------------------------------
# log_experiment: discard rolls HEAD back to pre-run snapshot
# ---------------------------------------------------------------------------
require "json"
require "open3"

def git(*args, chdir:)
  out, status = Open3.capture2e("git", *args, chdir: chdir)
  raise "git #{args.join(' ')} failed: #{out}" unless status.success?
  out.strip
end

Dir.mktmpdir do |tmp|
  ENV["CLAUDE_PROJECT_DIR"] = tmp

  git("init", "--quiet", chdir: tmp)
  git("config", "user.email", "test@autoresearch.local", chdir: tmp)
  git("config", "user.name", "Autoresearch Test", chdir: tmp)
  git("config", "commit.gpgsign", "false", chdir: tmp)
  File.write(File.join(tmp, "src.rb"), "# v0\n")
  git("add", "-A", chdir: tmp)
  git("commit", "-m", "initial", "--quiet", chdir: tmp)
  baseline_head = git("rev-parse", "HEAD", chdir: tmp)

  # Simulate an experiment commit
  File.write(File.join(tmp, "src.rb"), "# v1\n")
  git("add", "-A", chdir: tmp)
  git("commit", "-m", "experiment", "--quiet", chdir: tmp)
  experiment_head = git("rev-parse", "HEAD", chdir: tmp)
  assert experiment_head != baseline_head, "Test setup: experiment commit advances HEAD"

  # Simulate run_experiment having captured the pre-run head as baseline
  File.write(File.join(tmp, ".autoresearch-pre-run"), baseline_head + "\n")
  # Simulate a config so log_experiment has somewhere to append
  File.write(File.join(tmp, "autoresearch.jsonl"), JSON.generate(
    "type" => "config", "name" => "t", "metricName" => "ms",
    "metricUnit" => "ms", "bestDirection" => "lower"
  ) + "\n")

  # Discard: log_experiment should reset HEAD back to baseline
  Dir.chdir(tmp) do
    require_relative "../mcp/lib/autoresearch/tools/log_experiment"
    Autoresearch::Tools::LogExperiment.call(
      commit: experiment_head[0, 7],
      metric: 100.0,
      status: "discard",
      description: "test discard"
    )
  end

  current_head = git("rev-parse", "HEAD", chdir: tmp)
  assert current_head == baseline_head,
         "log_experiment(discard): HEAD reset to pre-run snapshot"
  assert File.read(File.join(tmp, "src.rb")) == "# v0\n",
         "log_experiment(discard): working tree restored to pre-run state"
  assert !File.exist?(File.join(tmp, ".autoresearch-pre-run")),
         "log_experiment: deletes .autoresearch-pre-run after handling"
end

puts "\nAll checks passed."
