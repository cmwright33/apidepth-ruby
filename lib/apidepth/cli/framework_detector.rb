# lib/apidepth/cli/framework_detector.rb
#
# Detects the web framework in the current directory by inspecting well-known
# files. Returns a framework identifier and the recommended initializer path.
# Used by `apidepth setup` to produce copy-paste-ready output.

module Apidepth
  module CLI
    module FrameworkDetector
      FRAMEWORKS = %i[rails sinatra].freeze

      DetectedFramework = Struct.new(:name, :initializer_path, :initializer_snippet, keyword_init: true)

      def self.detect(dir: Dir.pwd, api_key: nil, ignored_hosts: [], collector_url: nil)
        framework = _detect_framework(dir)
        _build_result(framework, api_key: api_key, ignored_hosts: ignored_hosts, collector_url: collector_url)
      end

      def self._detect_framework(dir)
        return :rails   if File.exist?(File.join(dir, "config/application.rb"))
        return :sinatra if File.exist?(File.join(dir, "config.ru"))

        :generic
      end

      def self._build_result(framework, api_key:, ignored_hosts:, collector_url:)
        key_val     = api_key       || "YOUR_API_KEY"
        url_val     = collector_url || "https://collector.apidepth.io"
        hosts_val   = ignored_hosts.empty? ? "[]" : ignored_hosts.map { |h| %("#{h}") }.join(", ").then { |s| "[#{s}]" }

        case framework
        when :rails
          snippet = <<~RUBY
            # config/initializers/apidepth.rb
            Apidepth.configure do |config|
              config.api_key       = #{key_val.inspect}
              config.collector_url = #{url_val.inspect}
              config.ignored_hosts = #{hosts_val}
            end
          RUBY
          DetectedFramework.new(
            name: :rails,
            initializer_path: "config/initializers/apidepth.rb",
            initializer_snippet: snippet
          )
        when :sinatra
          snippet = <<~RUBY
            # Top of your main app file (e.g. app.rb), before any routes
            require "apidepth"
            Apidepth.configure do |config|
              config.api_key       = #{key_val.inspect}
              config.collector_url = #{url_val.inspect}
              config.ignored_hosts = #{hosts_val}
            end
            Apidepth.instrument!
          RUBY
          DetectedFramework.new(
            name: :sinatra,
            initializer_path: nil,
            initializer_snippet: snippet
          )
        else
          snippet = <<~RUBY
            # Add to your application startup file
            require "apidepth"
            Apidepth.configure do |config|
              config.api_key       = #{key_val.inspect}
              config.collector_url = #{url_val.inspect}
              config.ignored_hosts = #{hosts_val}
            end
            Apidepth.instrument!
          RUBY
          DetectedFramework.new(
            name: :generic,
            initializer_path: nil,
            initializer_snippet: snippet
          )
        end
      end
    end
  end
end
