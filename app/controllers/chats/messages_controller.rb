# frozen_string_literal: true

module Chats
  # Sending, editing, soft-deleting, and re-rendering message bubbles.
  class MessagesController < ApplicationController
    before_action :set_conversation
    before_action :set_message, only: %i[show update destroy]
    before_action :require_ownership!, only: %i[update destroy]

    # Per-sender send throttle via Rails 8's built-in controller rate
    # limiting (https://api.rubyonrails.org/classes/ActionController/RateLimiting.html).
    # Feature-detected so the gem still loads on Rails 7.1 (where this is
    # simply not enforced). Keyed by messager, not IP — one abusive account
    # behind a corporate NAT must not silence the rest.
    if respond_to?(:rate_limit) && Chats.config.send_rate_limit
      rate_limit(
        **Chats.config.send_rate_limit,
        only: :create,
        by: -> { send(Chats.config.current_messager_method)&.to_gid&.to_s || request.remote_ip },
        with: -> { head :too_many_requests }
      )
    end

    # A single bubble, re-rendered. Exists for one delightful reason: it's
    # the "cancel edit" target — replacing the inline edit form back with the
    # plain bubble via one turbo_stream GET, no full page reload.
    def show
      render_bubble_replacement
    end

    def create
      @message = @conversation.messages.new(message_params.merge(sender: chats_current_messager))

      if @message.save
        respond_to do |format|
          # The sender's OWN bubble appends instantly from this response (no
          # waiting for the Action Cable round-trip); the broadcast then
          # delivers the same element to everyone else — and to the sender
          # again, where Turbo's append dedup (same DOM id) makes it a no-op.
          format.turbo_stream
          format.html { redirect_to conversation_path(@conversation) }
        end
      elsif locked?
        # The subject closed the conversation (Chats::ChatSubject#
        # chat_locked?) — possibly while this composer sat open. Swap the
        # composer for the locked notice instead of flashing an error at
        # someone whose screen is now lying to them. 422, never a raise.
        respond_to do |format|
          format.turbo_stream { render :locked, status: :unprocessable_entity }
          format.html do
            redirect_to conversation_path(@conversation), alert: @conversation.locked_notice
          end
        end
      else
        respond_to do |format|
          format.turbo_stream { render :errors, status: :unprocessable_entity }
          format.html do
            redirect_to conversation_path(@conversation),
                        alert: @message.errors.full_messages.to_sentence
          end
        end
      end
    end

    # Swap the bubble for an inline edit form (turbo_stream), with a plain
    # page as the no-JS fallback.
    # Edits arrive from the COMPOSER (the long-press → Editar flow re-targets
    # the composer form at this URL with _method=patch), so failures render
    # into the composer's error slot — same surface as failed sends.
    def update
      @message.edit!(message_params[:body])
      render_bubble_replacement
    rescue ActiveRecord::RecordInvalid, Chats::NotAllowedError
      render :errors, status: :unprocessable_entity
    end

    # Soft delete by default: tombstone the bubble (see Message#soft_delete!).
    def destroy
      @message.soft_delete!

      respond_to do |format|
        format.turbo_stream do
          if @message.destroyed?
            render turbo_stream: turbo_stream.remove(@message)
          else
            render_bubble_replacement
          end
        end
        format.html { redirect_to conversation_path(@conversation) }
      end
    end

    private

    def set_conversation
      @conversation = find_conversation(params[:conversation_id])
    end

    # Did THIS save fail because the conversation is locked? Reads the error
    # type, not the conversation, so a message that also failed validation
    # for another reason still reports that reason.
    def locked?
      @message.errors.of_kind?(:base, :locked)
    end

    def set_message
      @message = @conversation.messages.find(params[:id])
    end

    # Editing/deleting is for the author alone. 404 (not 403) so the action's
    # existence mirrors what the actor can see — consistent with every other
    # authorization miss in the engine.
    def require_ownership!
      raise ActiveRecord::RecordNotFound unless @message.sent_by?(chats_current_messager)
    end

    def message_params
      permitted = %i[body reply_to_id]
      permitted << { files: [] } if Chats.config.attachments
      params.require(:message).permit(*permitted)
    end

    def render_bubble_replacement
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace(
            @message,
            partial: "chats/messages/message",
            locals: { message: @message }
          )
        end
        format.html { redirect_to conversation_path(@conversation) }
      end
    end
  end
end
