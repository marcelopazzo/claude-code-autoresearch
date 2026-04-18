# frozen_string_literal: true

require "puma"
require "puma/configuration"
require "puma/launcher"
require_relative "app"

module Autoresearch
  module Dashboard
    # Standalone Puma launcher for the dashboard. Invoked by the
    # /autoresearch export slash command so users can view results live.
    module Server
      DEFAULT_HOST = "127.0.0.1"
      DEFAULT_PORT = 8765

      module_function

      def run(host: DEFAULT_HOST, port: DEFAULT_PORT)
        app = App.new
        config = Puma::Configuration.new do |c|
          c.bind "tcp://#{host}:#{port}"
          c.app app
          c.threads 0, 4
          c.workers 0
          c.log_writer Puma::LogWriter.stdio
        end
        puts "🔬 autoresearch dashboard → http://#{host}:#{port}"
        Puma::Launcher.new(config).run
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  host = ENV["AUTORESEARCH_HOST"] || Autoresearch::Dashboard::Server::DEFAULT_HOST
  port = Integer(ENV["AUTORESEARCH_PORT"] || Autoresearch::Dashboard::Server::DEFAULT_PORT)
  Autoresearch::Dashboard::Server.run(host: host, port: port)
end
