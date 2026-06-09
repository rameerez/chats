# frozen_string_literal: true

require "rails/generators/base"

module Chats
  module Generators
    # `rails generate chats:views` — eject the engine's overridable templates
    # into the HOST app so they can be restyled. This is the Devise move
    # (`rails g devise:views`), and it works for the same boring Rails reason:
    # the host app's `app/views` sits AHEAD of any engine's view paths in the
    # lookup chain, so a file copied to e.g.
    # `app/views/chats/messages/_message.html.erb` SHADOWS the gem's bundled
    # default automatically — no config, no registration. Delete your copy
    # and the gem's default comes back. Upgrade the gem and your ejected
    # copies are untouched (re-run only if you WANT the new defaults).
    #
    # `source_root` points at the engine's own `app/views`, so `directory`
    # copies the exact templates the engine renders.
    class ViewsGenerator < Rails::Generators::Base
      source_root File.expand_path("../../../app/views", __dir__)

      desc "Copy chats' overridable views into your app so you can restyle them."

      # Which groups to eject. Default copies everything renderable.
      class_option :views,
                   type: :array,
                   default: %w[conversations messages shared],
                   desc: "Which view groups to copy (conversations, messages, shared)"

      def copy_views
        directory "chats/conversations", "app/views/chats/conversations" if include?("conversations")
        directory "chats/messages", "app/views/chats/messages" if include?("messages")
        directory "chats/shared", "app/views/chats/shared" if include?("shared")
      end

      def show_styling_tip
        say "\n🎨 Views copied. They render with the gem's bundled chats.css by default;"
        say "   restyle freely — if your app uses Tailwind, classes you add here are"
        say "   picked up by your build automatically (the files now live in app/views)."
      end

      private

      def include?(group)
        options[:views].map(&:to_s).include?(group)
      end
    end
  end
end
