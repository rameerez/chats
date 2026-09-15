# frozen_string_literal: true

# A HEADLESS messager: the shape a support desk, a bot or an org mailbox
# takes. It converses like any other messager, but it is never notified,
# never blocked/reported, and every thread with it stacks into one inbox row.
#
# This is the model the whole point of chats 0.2.0 is measured against: a
# host should need ZERO class checks to get all three behaviours.
class Desk < ApplicationRecord
  acts_as_messager notifications: false, blockable: false, inbox: :grouped

  def display_name
    name
  end
end
