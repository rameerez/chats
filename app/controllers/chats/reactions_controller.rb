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
  end
end
