# frozen_string_literal: true

# Load the Rails application.
require_relative "application"

# Initialize the Rails application. This runs every initializer, including
# the engine's (Chats::Engine) and the dummy's own
# config/initializers/chats.rb, so by the time test_helper.rb requires this
# file the gem is fully wired.
Rails.application.initialize!
