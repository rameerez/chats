# frozen_string_literal: true

# Test the minimum supported Rails version (matches the gemspec floor). The
# adaptive migration template and the `rate_limit` guard (a Rails 8.0+ API,
# feature-detected in Chats::MessagesController) must both work here.
appraise "rails-7.1" do
  gem "rails", "~> 7.1.0"
end

appraise "rails-7.2" do
  gem "rails", "~> 7.2.0"
end

# Test the latest Rails version — this is the default/main Gemfile anyway.
appraise "rails-8.1" do
  gem "rails", "~> 8.1.0"
end
