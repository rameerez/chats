# frozen_string_literal: true

module Chats
  # Abstract base for every chats model. Kept separate from the host's
  # ApplicationRecord on purpose: the gem's models must not inherit host
  # callbacks/scopes, and the host must be able to swap its own base class
  # without touching ours.
  class ApplicationRecord < ActiveRecord::Base
    self.abstract_class = true
  end
end
