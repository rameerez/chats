# frozen_string_literal: true

module Chats
  # Base controller for every engine screen. It inherits from the HOST's
  # controller (config.parent_controller, "::ApplicationController" by
  # default) so the host's layout, helpers, auth filters, locale switching
  # and exception handling all apply to the chat screens for free — the same
  # integration style as api_keys' dashboard.
  #
  # NOTE: the superclass is resolved when this class is autoloaded, which in
  # a booted app happens AFTER initializers — so `config.parent_controller`
  # set in config/initializers/chats.rb is honored. In development the class
  # is reloaded on every change, picking up config changes too.
  class ApplicationController < Chats.config.parent_controller.constantize
    before_action :chats_authenticate!

    helper Chats::EngineHelper
    helper_method :chats_current_messager

    layout :chats_layout

    private

    # The conversing actor for this request, via the host-configured method
    # (`current_user` by default — Devise-compatible out of the box).
    def chats_current_messager
      @chats_current_messager ||= begin
        method_name = Chats.config.current_messager_method
        unless respond_to?(method_name, true)
          raise Chats::ConfigurationError,
                "chats can't find ##{method_name} on #{self.class.superclass.name}. " \
                "Set config.current_messager_method in config/initializers/chats.rb " \
                "to the controller method that returns the logged-in #{Chats.config.messager_class}."
        end

        send(method_name)
      end
    end

    def chats_authenticate!
      method_name = Chats.config.authenticate_method
      unless respond_to?(method_name, true)
        raise Chats::ConfigurationError,
              "chats can't find ##{method_name} on #{self.class.superclass.name}. " \
              "Set config.authenticate_method in config/initializers/chats.rb " \
              "to your authentication filter (e.g. :authenticate_user! with Devise)."
      end

      send(method_name)
    end

    # nil falls through to the parent controller's regular layout resolution,
    # so by default chat screens look like the rest of the host app.
    def chats_layout
      Chats.config.layout
    end

    # Conversations are ALWAYS resolved through the viewer's own inbox
    # relation: not-a-participant, left, or blocked-counterpart threads all
    # come back as a plain 404 — existence is never leaked to outsiders.
    def find_conversation(id = params[:id])
      chats_current_messager.chats.find(id)
    end
  end
end
