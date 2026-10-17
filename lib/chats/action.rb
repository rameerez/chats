# frozen_string_literal: true

module Chats
  # The one featured button a message can carry: a label and the place it
  # takes you.
  #
  #   alice.message!(bob, "Let's play!", action: { label: "Join my room", url: "/play/friend/abcd" })
  #
  #   message.action        # => #<data Chats::Action label="Join my room", url="/play/friend/abcd">
  #   message.action.label  # => "Join my room"
  #   message.action.to_h   # => { label: "Join my room", url: "/play/friend/abcd" }
  #
  # An immutable value, compared by value: two actions with the same label
  # and url are the same action. It knows nothing about what makes one safe
  # to render — Chats::Message validates that at the write, where a bad one
  # can fail loudly instead of rendering a dead or dangerous link.
  Action = Data.define(:label, :url) do
    # Whatever a host hands `action:` — nil, a Hash (string or symbol keys),
    # or an Action — as an Action, or nil.
    #
    # Unknown keys raise rather than vanish: `{ label:, url:, method: :post }`
    # silently becoming a GET link is exactly the surprise this refuses.
    def self.wrap(value)
      case value
      when nil, self then value
      when Hash
        attributes = value.to_h { |key, attribute| [key.to_s, attribute] }
        unknown = attributes.keys - members.map(&:to_s)
        if unknown.any?
          raise ArgumentError, "unknown action keys: #{unknown.join(", ")} (an action is a label and a url)"
        end

        new(label: attributes["label"], url: attributes["url"])
      else
        raise ArgumentError, "an action is a Hash with a label and a url, or a Chats::Action — got #{value.inspect}"
      end
    end

    # Both are text by the time they're stored: a path helper's String, a
    # URI, a symbol label — all read back as the String the column holds.
    # nil stays nil so a missing one is a validation error, not a "" that
    # looks present.
    #
    # Each is a frozen, PLAIN String copy. `Data` freezes the action, not the
    # strings it was handed, so without the copy `action.url.replace(
    # "javascript:…")` would rewrite a validated action in place — and so
    # would the caller mutating the string they passed in. Plain, because
    # `String.new` drops an html_safe mark: a label that arrived as a
    # SafeBuffer (a host's `t("…_html")`) would otherwise render unescaped
    # in the button. An action is a value: what the validator saw is what
    # the bubble renders, and the bubble escapes it like any other content.
    def initialize(label:, url:)
      super(label: plain(label), url: plain(url))
    end

    private

    def plain(value)
      String.new(value.to_s).freeze unless value.nil?
    end
  end

  class Action
    # How `chats_messages.action` (json/jsonb) reads and writes: an Action
    # or nil on the Ruby side, `{"label":…,"url":…}` in the column. Every
    # assignment goes through Action.wrap, so a Hash, an Action and nil all
    # work, and anything else raises right where it was assigned.
    class Type < ActiveRecord::Type::Json
      def cast(value)
        Action.wrap(value)
      end

      # Reads only the two keys an action has, so a row written by a later
      # version with more of them still loads instead of raising.
      def deserialize(value)
        stored = super
        Action.wrap(stored.slice("label", "url")) if stored.is_a?(Hash)
      end

      def serialize(value)
        super(Action.wrap(value)&.to_h)
      end
    end
  end
end
