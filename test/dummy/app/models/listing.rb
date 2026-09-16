# frozen_string_literal: true

# A host domain record conversations can be *about* (like, a specific order
# inside an app like Uber — chats attach to it via `about:`).
#
# It is also the suite's LOCKABLE subject: flipping `locked` closes every
# conversation about it for writing, while leaving the history readable.
class Listing < ApplicationRecord
  acts_as_chat_subject

  def chat_subject_label
    title
  end

  def chat_locked?
    locked?
  end

  def chat_locked_notice
    "This listing is closed." if locked?
  end
end
