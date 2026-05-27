# Rakefile — minimal release task for rubygems/release-gem@v1
#
# The CI action (rubygems/release-gem@v1) handles OIDC credential setup and
# then calls `bundle exec rake release`. We skip bundler's default gem helper
# (which would try to re-tag) and just push the pre-built .gem file.

desc "Push gem to RubyGems (called by rubygems/release-gem@v1 in CI)"
task :release do
  gems = Dir["pkg/apidepth-*.gem"]
  if gems.empty?
    abort "No .gem file found in pkg/. Run: mkdir -p pkg && gem build apidepth.gemspec && mv apidepth-*.gem pkg/"
  end
  gems.each { |g| sh "gem push #{g}" }
end
