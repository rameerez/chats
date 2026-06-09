# frozen_string_literal: true

module Chats
  # View helpers, available BOTH inside the engine's own views and in the
  # HOST app's views (mixed into ActionView via the engine's on_load hook,
  # the same pattern the moderate gem uses for `report_link`).
  module EngineHelper
    # The "message this person" affordance for host pages — a listing, a
    # profile, an order. Renders nothing when there's no viewer, the viewer
    # IS the target, or policy/blocks forbid the pair, so it's always safe
    # to drop into a page unconditionally:
    #
    #   <%= chat_button_to @driver, about: @ride, label: "Chat with driver" %>
    #
    # The recipient/subject travel as SIGNED GlobalIDs (purpose-scoped,
    # minted here, verified in Chats::ConversationsController#create), so the
    # endpoint never trusts raw polymorphic params. `expires_in: nil` because
    # these buttons sit on long-lived pages — the default 1-month sgid expiry
    # would quietly break stale tabs.
    def chat_button_to(other, about: nil, label: nil, **html_options)
      viewer = chats_viewer
      return if viewer.nil? || other.nil? || viewer == other
      return unless Chats.can_message?(viewer, other)

      params = { recipient_sgid: other.to_sgid(expires_in: nil, for: :chats_recipient).to_s }
      params[:subject_sgid] = about.to_sgid(expires_in: nil, for: :chats_subject).to_s if about

      button_to(
        label || I18n.t("chats.buttons.chat"),
        chats_routes.conversations_path,
        params: params,
        method: :post,
        **html_options
      )
    end

    # A live unread-conversations badge, embeddable on ANY page (nav bars,
    # tab docks). Subscribes to the messager's badge stream so it updates in
    # real time without refreshing the page it sits on (see
    # Chats::Broadcasts for why badges get their own stream).
    def chats_unread_badge(messager = chats_viewer)
      return if messager.nil?

      safe_join([
                  turbo_stream_from(messager, :chats_badge),
                  render(partial: "chats/shared/unread_badge", locals: { count: messager.unread_chats_count })
                ])
    end

    # An avatar for any messager: whatever `config.messager_avatar` returns
    # (URL / ActiveStorage attachment / variant) or an initials placeholder.
    def chats_messager_avatar(messager, css_class: "chats-avatar")
      name = Chats.display_name_for(messager).presence || "?"
      source = begin
        avatar = Chats.avatar_for(messager)
        # An ActiveStorage attachment that isn't attached renders as a broken
        # image — treat it as "no avatar" instead.
        avatar.respond_to?(:attached?) && !avatar.attached? ? nil : avatar
      end

      if source
        image_tag source, alt: name, class: css_class, loading: "lazy"
      else
        initials = name.split.first(2).map { |word| word[0] }.join.upcase
        tag.span(initials, class: "#{css_class} chats-avatar--initials", "aria-hidden": true)
      end
    end

    # WhatsApp-style compact timestamps, deliberately numeric so they need no
    # date-name translations (many apps don't bundle rails-i18n; the gem must
    # not require it): today → "14:05", this week-ish → "9/6", older → "9/6/25".
    def chats_timestamp(time)
      return "" if time.nil?

      local = time.in_time_zone
      if local.today?
        local.strftime("%H:%M")
      elsif local.year == Time.current.year
        local.strftime("%-d/%-m")
      else
        local.strftime("%-d/%-m/%y")
      end
    end

    # The inbox-row preview line for a conversation's latest message.
    def chats_preview_for(conversation, viewer)
      message = conversation.last_message
      return I18n.t("chats.inbox.no_messages") if message.nil?

      text =
        if message.deleted?
          I18n.t("chats.message.deleted")
        elsif message.body.present?
          message.body.truncate(90)
        elsif message.attachments?
          "📷 #{I18n.t("chats.message.attachment")}"
        else
          ""
        end

      # Tombstones read as a statement ("Message deleted"), not as something
      # the viewer said — no "You:" prefix.
      prefix = I18n.t("chats.inbox.you_prefix") if message.sent_by?(viewer) && !message.deleted?
      [prefix, text].compact.join(" ")
    end

    # The avatar shown on an inbox row: the counterpart's (direct) or an
    # initials disc from the group name.
    def chats_conversation_avatar(conversation, viewer)
      if conversation.direct?
        other = conversation.other_participants(viewer).first
        chats_messager_avatar(other&.messager)
      else
        initials = conversation.title_for(viewer).split.first(2).map { |word| word[0] }.join.upcase
        tag.span(initials.presence || "👥", class: "chats-avatar chats-avatar--initials chats-avatar--group",
                                           "aria-hidden": true)
      end
    end

    # The gem's bundled stylesheet (CSS-variable themed — see chats.css).
    # Called from the engine's own views; hosts that eject + restyle the
    # views with their own framework simply don't include it.
    def chats_styles
      stylesheet_link_tag "chats", "data-turbo-track": "reload"
    end

    # Engine URL helpers that work from EVERY render context — this is more
    # subtle than it looks, and the reason the broadcast partials use it:
    #
    #   * host views & the broadcast renderer (Turbo broadcasts render through
    #     the host's ApplicationController renderer — no engine request, no
    #     SCRIPT_NAME): the mounted proxy (`chats.`) carries the mount prefix
    #     baked in at mount time, so URLs come out right with no request.
    #   * engine views during requests: the engine controller inherits from
    #     the host's ApplicationController, so the proxy is available there
    #     too (and bare helpers would also work — the proxy just works
    #     everywhere).
    #   * no mount at all (bare view tests): fall back to the engine's own
    #     url_helpers (prefix-less, but nothing better exists without a mount).
    #
    # NOTE: assumes the default mount name (`mount Chats::Engine => "/x"`
    # auto-names the proxy `chats`). Hosts using `as: :something_else` should
    # override this helper.
    def chats_routes
      respond_to?(:chats) ? chats : Chats::Engine.routes.url_helpers
    end

    private

    # The current messager in whatever context the helper runs (host or
    # engine view), resolved through the configured controller method.
    def chats_viewer
      method_name = Chats.config.current_messager_method
      respond_to?(method_name) ? send(method_name) : nil
    end
  end
end
