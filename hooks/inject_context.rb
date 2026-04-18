#!/usr/bin/env ruby
# frozen_string_literal: true

# UserPromptSubmit hook — when autoresearch mode is on, inject the session
# doc and the tail of the jsonl into the prompt so the agent always has full
# context. When mode is off, do nothing.
#
# stdin:  { "prompt": "...", "cwd": "...", ... }
# stdout: additionalContext text (appended to the user's prompt)

require "json"
require_relative "../mcp/lib/autoresearch"

begin
  input = JSON.parse($stdin.read)
rescue JSON::ParserError
  exit 0
end

# Let the hook see the project cwd the user is actually in.
ENV["CLAUDE_PROJECT_DIR"] ||= input["cwd"] if input.is_a?(Hash) && input["cwd"]

exit 0 unless Autoresearch::Mode.on?
exit 0 unless File.exist?(Autoresearch::Paths.md_path)

md_contents = File.read(Autoresearch::Paths.md_path)
jsonl_tail = if File.exist?(Autoresearch::Paths.jsonl_path)
               File.readlines(Autoresearch::Paths.jsonl_path, chomp: true).last(10).join("\n")
             else
               ""
             end

context = +"# Autoresearch session context\n\n"
context << "You are in autoresearch mode. Treat the session document below as\n"
context << "the source of truth for the optimization goal, files in scope, and\n"
context << "past attempts. Continue the experiment loop: edit → commit →\n"
context << "run_experiment → log_experiment → keep or revert → repeat.\n\n"
context << "## autoresearch.md\n\n"
context << md_contents
unless jsonl_tail.empty?
  context << "\n\n## Last 10 jsonl entries\n\n"
  context << "```\n"
  context << jsonl_tail
  context << "\n```\n"
end

puts context
exit 0
