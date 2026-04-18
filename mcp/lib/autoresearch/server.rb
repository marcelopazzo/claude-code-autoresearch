# frozen_string_literal: true

require "mcp"
require_relative "../autoresearch"
require_relative "tools/init_experiment"
require_relative "tools/run_experiment"
require_relative "tools/log_experiment"

module Autoresearch
  module Server
    module_function

    def build
      MCP::Server.new(
        name: "autoresearch",
        version: Autoresearch::VERSION,
        tools: [
          Autoresearch::Tools::InitExperiment,
          Autoresearch::Tools::RunExperiment,
          Autoresearch::Tools::LogExperiment
        ]
      )
    end

    def run_stdio
      server = build
      transport = MCP::Server::Transports::StdioTransport.new(server)
      transport.open
    end
  end
end
