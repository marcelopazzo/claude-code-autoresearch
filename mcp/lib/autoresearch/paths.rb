# frozen_string_literal: true

require "pathname"

module Autoresearch
  module Paths
    module_function

    # Session cwd = the directory Claude Code launched in.
    # Config file (autoresearch.config.json) always lives here.
    def session_cwd
      ENV["CLAUDE_PROJECT_DIR"] || Dir.pwd
    end

    # Working dir = where autoresearch.md/sh/jsonl live and commands run.
    # Defaults to session_cwd; can be overridden via config.workingDir.
    def work_dir
      cfg = Config.load(session_cwd)
      override = cfg["workingDir"]
      return session_cwd if override.nil? || override.to_s.empty?

      resolved = Pathname.new(override)
      resolved = Pathname.new(session_cwd).join(resolved) unless resolved.absolute?
      resolved.to_s
    end

    def jsonl_path    = File.join(work_dir, "autoresearch.jsonl")
    def md_path       = File.join(work_dir, "autoresearch.md")
    def sh_path       = File.join(work_dir, "autoresearch.sh")
    def checks_path   = File.join(work_dir, "autoresearch.checks.sh")
    def ideas_path    = File.join(work_dir, "autoresearch.ideas.md")
    def mode_path     = File.join(work_dir, ".autoresearch-mode")
    def config_path   = File.join(session_cwd, "autoresearch.config.json")
  end
end
