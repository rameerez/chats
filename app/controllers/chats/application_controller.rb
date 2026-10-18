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

    # Conversations are ALWAYS resolved through relations that only hold
    # what this viewer may open (conversation_lookup_scopes): not a
    # participant, left, or a blocked counterpart all come back as a plain
    # 404, the same 404 as an id that doesn't exist — existence is never
    # leaked to outsiders. Every engine endpoint (the thread, a dock window,
    # sending, editing, reacting, reading) looks a conversation up here.
    #
    # The first scope that has it wins; later scopes are asked only on a
    # miss. Errors a scope raises are not rescued: a broken product scope
    # must fail loudly, never turn into a quiet 404.
    def find_conversation(id = params[:id])
      conversation_lookup_scopes.each do |scope|
        conversation = scope.find_by(id: id)
        return conversation if conversation
      end

      raise ActiveRecord::RecordNotFound.new(
        "Couldn't find Chats::Conversation with 'id'=#{id}", Chats::Conversation.name, "id", id
      )
    end

    protected

    # Where find_conversation looks, in order: by default the viewer's own
    # inbox relation (`Messager#chats`: their active seats, blocks and
    # `config.inbox_scope` applied).
    #
    # THE extension point for a conversation that must open although the
    # inbox hides it. A product gem built on chats (support_desk: a
    # requester's own ticket, which the host's inbox_scope keeps out of the
    # inbox) prepends a module that appends its own relation:
    #
    #   module SupportDesk::ConversationLookup
    #     protected
    #
    #     def conversation_lookup_scopes
    #       super + [SupportDesk::Ticket.conversations_of(chats_current_messager)]
    #     end
    #   end
    #   Chats::ApplicationController.prepend(SupportDesk::ConversationLookup)
    #
    # Each scope must hold only conversations this viewer may open: the
    # union of the scopes IS the authorization. Nothing the scopes don't
    # name becomes reachable.
    def conversation_lookup_scopes
      [chats_current_messager.chats]
    end
  end
end
