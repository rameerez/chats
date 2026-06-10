# frozen_string_literal: true

# A host domain record conversations can be *about* (like, a specific order
# inside an app like Uber — chats attach to it via `about:`).
class Listing < ApplicationRecord
  acts_as_chat_subject

  def chat_subject_label
    title
  end
end
