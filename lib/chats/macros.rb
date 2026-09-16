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
    # Options (all optional; the defaults are 0.1.x behaviour):
    #
    #   notifications: false   this messager is never notifiable — a support
    #                          desk, a bot, an org mailbox. `Participant#
    #                          notifiable_for?` says no, so hosts stop
    #                          branching on class in every notifier.
    #   blockable: false       block/report affordances don't apply to it, so
    #                          the bundled views hide them.
    #   inbox: :grouped        every direct conversation with this messager
    #                          stacks into ONE inbox row (see Chats::Inbox).
    #   group_path: ->(viewer) { }  where that stacked row links to; defaults
    #                          to the filtered inbox (`?with=<sgid>`).
    #
    #   class Desk < ApplicationRecord
    #     acts_as_messager notifications: false, blockable: false, inbox: :grouped
    #   end
    def acts_as_messager(notifications: true, blockable: true, inbox: :default, group_path: nil)
      include Chats::Messager

      self.chat_options = Chats::Messager.normalize_options(
        notifications: notifications,
        blockable: blockable,
        inbox: inbox,
        group_path: group_path
      )
    end

    def acts_as_chat_subject
      include Chats::ChatSubject
    end
  end
end
