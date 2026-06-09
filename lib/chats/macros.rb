# frozen_string_literal: true

module Chats
  # The two host-facing macros. The engine extends `ActiveRecord::Base` with
  # this module (via `ActiveSupport.on_load(:active_record)`), so any model
  # can declare:
  #
  #   class User < ApplicationRecord
  #     acts_as_messager            # can converse: inbox, DMs, groups
  #   end
  #
  #   class Ride < ApplicationRecord
  #     acts_as_chat_subject        # conversations can be *about* a ride
  #   end
  #
  # Each macro just includes the corresponding concern — all the behavior
  # lives in Chats::Messager / Chats::ChatSubject so it's discoverable,
  # testable, and `include`-able directly when a host prefers that style.
  module Macros
    def acts_as_messager
      include Chats::Messager
    end

    def acts_as_chat_subject
      include Chats::ChatSubject
    end
  end
end
