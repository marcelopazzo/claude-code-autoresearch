# frozen_string_literal: true

require "open3"

module Autoresearch
  # Run a shell command with a timeout, capture a bounded tail, and kill
  # the process group on timeout. Designed for benchmark scripts that
  # print `METRIC name=value` lines on stdout.
  class Runner
    DEFAULT_TIMEOUT = 600
    MAX_LINES = 10
    MAX_BYTES = 4 * 1024

    Result = Struct.new(
      :command, :exit_code, :duration_s, :timed_out, :tail, :full_output,
      keyword_init: true
    )

    def self.run(command:, work_dir:, timeout_s: DEFAULT_TIMEOUT, env: {})
      started = monotonic_now
      full_output = +""
      timed_out = false
      exit_code = nil

      Open3.popen2e(env, command, chdir: work_dir, pgroup: true) do |_stdin, out, wait_thr|
        deadline = started + timeout_s

        loop do
          remaining = deadline - monotonic_now
          if remaining <= 0
            timed_out = true
            kill_tree(wait_thr.pid)
            break
          end

          ready = IO.select([out], nil, nil, [remaining, 0.25].min)
          next unless ready

          begin
            chunk = out.read_nonblock(4096)
            full_output << chunk
          rescue IO::WaitReadable
            next
          rescue EOFError
            break
          end
        end

        unless timed_out
          wait_thr.value # reap
          exit_code = wait_thr.value.exitstatus
        end
      end

      duration = monotonic_now - started

      Result.new(
        command: command,
        exit_code: exit_code,
        duration_s: duration,
        timed_out: timed_out,
        tail: tail(full_output),
        full_output: full_output
      )
    end

    def self.monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # Return the last MAX_LINES lines (capped at MAX_BYTES) from `output`.
    def self.tail(output)
      lines = output.to_s.lines
      tail_lines = lines.last(MAX_LINES)
      joined = tail_lines.join
      joined = joined.byteslice(-MAX_BYTES, MAX_BYTES) if joined.bytesize > MAX_BYTES
      joined
    end

    def self.kill_tree(pid)
      # Kill the whole process group we created via `pgroup: true`.
      Process.kill("-TERM", pid)
      sleep 0.2
      begin
        Process.kill("-KILL", pid)
      rescue Errno::ESRCH
        # already dead
      end
    rescue Errno::ESRCH, Errno::EPERM
      # process already exited or not ours
    end
  end
end
