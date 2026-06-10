# frozen_string_literal: true

# The dummy host's conversing model — the README's one-liner.
class User < ApplicationRecord
  acts_as_messager
  has_one_attached :avatar

  # Exercised by the default messager_display_name proc (tries display_name
  # first) and by avatar fallbacks.
  def display_name
    name
  end
end
