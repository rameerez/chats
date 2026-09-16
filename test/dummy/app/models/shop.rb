# frozen_string_literal: true

# A VERIFIED messager that is otherwise completely ordinary: it is notified,
# it can be blocked, and every thread with it is its own inbox row.
#
# Desk covers "official AND headless"; Shop covers "official and nothing
# else", which is what keeps `verified:` an independent option instead of a
# synonym for `acts_as_messager notifications: false, blockable: false`.
class Shop < ApplicationRecord
  acts_as_messager verified: true

  def display_name
    name
  end
end
