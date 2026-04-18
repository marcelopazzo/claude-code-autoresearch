# frozen_string_literal: true

require "rack"
require_relative "../../autoresearch"

module Autoresearch
  module Dashboard
    # Tiny Rack app: serves the SPA at / and the raw jsonl at /autoresearch.jsonl.
    # The template polls the jsonl endpoint directly — no JSON API needed.
    class App
      TEMPLATE_PATH = File.join(__dir__, "template.html")
      TITLE_PLACEHOLDER = "__AUTORESEARCH_TITLE__"
      LOGO_PLACEHOLDER = "__AUTORESEARCH_LOGO__"

      def call(env)
        req = Rack::Request.new(env)
        case req.path
        when "/"
          [200, html_headers, [render_template]]
        when "/autoresearch.jsonl"
          path = Autoresearch::Paths.jsonl_path
          if File.exist?(path)
            [200,
             { "content-type" => "application/jsonl", "cache-control" => "no-store" },
             [File.read(path)]]
          else
            [404, { "content-type" => "text/plain" }, ["autoresearch.jsonl not found"]]
          end
        when "/healthz"
          [200, { "content-type" => "text/plain" }, ["ok"]]
        else
          [404, { "content-type" => "text/plain" }, ["not found"]]
        end
      end

      private

      def html_headers
        { "content-type" => "text/html; charset=utf-8", "cache-control" => "no-store" }
      end

      def render_template
        template = File.read(TEMPLATE_PATH)
        template
          .gsub(TITLE_PLACEHOLDER, "autoresearch — #{File.basename(Autoresearch::Paths.work_dir)}")
          .gsub(LOGO_PLACEHOLDER, "")
      end
    end
  end
end
