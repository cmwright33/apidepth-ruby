# lib/apidepth/cli/setup.rb
#
# Implements `bundle exec apidepth setup`.
#
# Interactive mode (default):
#   Opens the Apidepth dashboard in a browser so the developer can copy their
#   API key, then prompts for ignored host patterns and writes the initializer.
#
# Non-interactive mode (CI/CD and AI-assisted setup):
#   bundle exec apidepth setup --api-key $APIDEPTH_API_KEY --no-prompt
#   All prompts are bypassed; output goes to stdout only.

require "optparse"
require "apidepth/cli/framework_detector"

module Apidepth
  module CLI
    module Setup
      DASHBOARD_KEYS_URL = "https://apidepth.io/dashboard/api-keys".freeze

      def self.run(argv = ARGV)
        options = parse_options(argv)
        api_key = options[:api_key]
        collector_url = options[:collector_url]
        ignored_hosts = options[:ignored_hosts] || []
        no_prompt = options[:no_prompt]
        framework_override = options[:framework]

        # Interactive: open dashboard and prompt for key
        unless api_key || no_prompt
          $stdout.puts "\nApidepth SDK Setup"
          $stdout.puts "─" * 40
          $stdout.puts "\nOpening your API keys page..."
          _open_browser(DASHBOARD_KEYS_URL)
          $stdout.print "\nPaste your API key: "
          api_key = $stdin.gets&.strip
          if api_key.nil? || api_key.empty?
            warn "No API key provided. Aborting."
            exit 1
          end
        end

        # Interactive: prompt for ignored hosts
        unless no_prompt
          $stdout.puts "\nDefault ignored hosts (always skipped):"
          %w[localhost 127.0.0.1 0.0.0.0 ::1].each { |h| $stdout.puts "  • #{h}" }
          $stdout.puts "  • #{collector_url || 'collector.apidepth.io'}"
          $stdout.puts "\nAny internal API patterns to ignore? (comma-separated, wildcards ok)"
          $stdout.puts "  Examples: *.internal, *.local, *.svc.cluster.local, *.railway.internal"
          $stdout.print "> "
          input = $stdin.gets&.strip || ""
          ignored_hosts += input.split(",").map(&:strip).reject(&:empty?) unless input.empty?
        end

        result = FrameworkDetector.detect(
          dir: Dir.pwd,
          api_key: api_key,
          ignored_hosts: ignored_hosts,
          collector_url: collector_url
        )
        # Override detected framework if flag provided
        if framework_override
          result = FrameworkDetector.detect(
            dir: Dir.pwd,
            api_key: api_key,
            ignored_hosts: ignored_hosts,
            collector_url: collector_url
          )
        end

        _print_result(result, no_prompt: no_prompt)
      end

      def self.parse_options(argv)
        options = {}
        parser = OptionParser.new do |opts|
          opts.banner = "Usage: bundle exec apidepth setup [options]"
          opts.on("--api-key KEY", "API key (skips browser OAuth)") { |v| options[:api_key] = v }
          opts.on("--collector-url URL", "Override collector URL") { |v| options[:collector_url] = v }
          opts.on("--ignored-hosts HOSTS", "Comma-separated ignored host patterns") do |v|
            options[:ignored_hosts] = v.split(",").map(&:strip)
          end
          opts.on("--no-prompt", "Non-interactive mode; output to stdout only") { options[:no_prompt] = true }
          opts.on("--framework NAME", "Override framework detection (rails|sinatra|generic)") do |v|
            options[:framework] = v
          end
          opts.on_tail("-h", "--help", "Show this message") do
            puts opts
            exit
          end
        end
        begin
          parser.parse!(argv.dup)
        rescue OptionParser::InvalidOption => e
          warn e.message
          exit 1
        end
        options
      end

      def self._open_browser(url)
        if RUBY_PLATFORM.include?("darwin")
          system("open", url)
        elsif RUBY_PLATFORM.include?("linux")
          system("xdg-open", url)
        else
          $stdout.puts "Visit: #{url}"
        end
      end

      def self._print_result(result, no_prompt:)
        framework_label = result.name.to_s.capitalize
        $stdout.puts "\nDetected: #{framework_label}" unless no_prompt

        if result.initializer_path && !no_prompt
          $stdout.puts "\nAdd the following to #{result.initializer_path}:"
          $stdout.puts
          $stdout.puts result.initializer_snippet
          $stdout.print "Write to #{result.initializer_path}? [y/N] "
          answer = $stdin.gets&.strip&.downcase
          if answer == "y"
            full_path = File.join(Dir.pwd, result.initializer_path)
            FileUtils.mkdir_p(File.dirname(full_path))
            File.write(full_path, result.initializer_snippet)
            $stdout.puts "Written to #{result.initializer_path}"
          else
            $stdout.puts "(Not written — copy the snippet above into your codebase)"
          end
        else
          $stdout.puts result.initializer_snippet
        end
        $stdout.puts "\nRun `bundle exec apidepth test` to confirm events are reaching the collector." unless no_prompt
      end
    end
  end
end
