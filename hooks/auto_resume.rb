#!/usr/bin/env ruby
# frozen_string_literal: true

# Stop hook — while autoresearch mode is on and we haven't hit maxIterations,
# block the stop and tell Claude to keep looping. Respect the stop_hook_active
# guard so we never spin on an already-blocked stop.
#
# stdin:  { "stop_hook_active": bool, "cwd": "...", ... }
# stdout: JSON { "decision": "block", "reason": "..." } to continue,
#         or empty to allow the stop.

require "json"
require_relative "../mcp/lib/autoresearch"

begin
  input = JSON.parse($stdin.read)
rescue JSON::ParserError
  exit 0
end

ENV["CLAUDE_PROJECT_DIR"] ||= input["cwd"] if input.is_a?(Hash) && input["cwd"]

# Never fight a stop that's already being blocked — avoids infinite loops.
exit 0 if input.is_a?(Hash) && input["stop_hook_active"]

exit 0 unless Autoresearch::Mode.on?
exit 0 unless File.exist?(Autoresearch::Paths.md_path)

state = Autoresearch::State.load(Autoresearch::Paths.jsonl_path)
if state.at_iteration_limit?
  # Iteration cap reached — let the stop go through and leave a note.
  warn "[autoresearch] maxIterations reached (#{state.max_experiments}); not resuming."
  exit 0
end

response = {
  "decision" => "block",
  "reason" => "Autoresearch mode is on. Read autoresearch.md for context, then " \
              "run the next iteration: edit → commit → run_experiment → " \
              "log_experiment → keep or revert. Don't stop until the user runs " \
              "/autoresearch off or the iteration cap is hit."
}
puts JSON.generate(response)
exit 0
