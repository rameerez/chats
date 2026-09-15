# frozen_string_literal: true

module Chats
  # Emoji reactions: tap-to-toggle, one endpoint.
  class ReactionsController < ApplicationController
    # Toggle: adds or removes (Reaction.toggle! is race-safe through the
    # unique index). The response re-renders the bubble for the actor; the
    # broadcast updates everyone else.
    def create
      conversation = find_conversation(params[:conversation_id])
      message = conversation.messages.find(params[:message_id])
      return refuse_when_locked(conversation) if conversation.locked?

      Chats::Reaction.toggle!(
        message: message,
        reactor: chats_current_messager,
        emoji: params.require(:emoji)
      )

      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace(
            message,
            partial: "chats/messages/message",
            locals: { message: message }
          )
        end
        format.html { redirect_to conversation_path(conversation) }
      end
    rescue ActiveRecord::RecordInvalid
      head :unprocessable_entity
    end

    private

    # Same shape as the messages controller: swap the composer for the
    # reason, 422, never an exception page.
    def refuse_when_locked(conversation)
      @conversation = conversation

      respond_to do |format|
        format.turbo_stream { render "chats/messages/locked", status: :unprocessable_entity }
        format.html { redirect_to conversation_path(conversation), alert: conversation.locked_notice }
      end
    end
  end
end
