# frozen_string_literal: true

module Chats
  # View helpers, available BOTH inside the engine's own views and in the
  # HOST app's views (mixed into ActionView via the engine's on_load hook,
  # the same pattern the moderate gem uses for `report_link`).
  module EngineHelper
    # Every slot the bundled views render, and the whole list of them. A
    # host drops `app/views/chats/slots/_<name>.html.erb` in and it appears;
    # a name that isn't here renders nothing.
    SLOTS = %w[
      inbox_top
      inbox_empty
      conversation_header_actions
      locked_composer
      message_meta
    ].freeze

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
    def chats_messager_avatar(messager, css_class: "chats-avatar", loading: "eager")
      name = Chats.display_name_for(messager).presence || "?"
      source = begin
        avatar = Chats.avatar_for(messager)
        # An ActiveStorage attachment that isn't attached renders as a broken
        # image — treat it as "no avatar" instead.
        avatar.respond_to?(:attached?) && !avatar.attached? ? nil : avatar
      end

      if source
        image_tag chats_avatar_image_source(source), alt: name, class: css_class, loading: loading
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

      # Tombstones read as a statement ("Message deleted") — never prefixed.
      # Otherwise: "You:" for own messages, and in GROUPS the sender's first
      # name (WhatsApp-style), since "who said it" is ambiguous there. System
      # messages (no sender) stay bare.
      prefix =
        if message.deleted?
          nil
        elsif message.sent_by?(viewer)
          I18n.t("chats.inbox.you_prefix")
        elsif conversation.group? && message.sender
          "#{Chats.display_name_for(message.sender).split.first}:"
        end
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

    # --- Slots ----------------------------------------------------------------
    #
    # Named extension points the bundled views render WHEN a partial exists
    # at `chats/slots/_<name>`. Hosts (and engines mounted on top of chats,
    # like support_desk) drop a file in and it appears; nobody has to eject
    # a whole screen to add one row or one button. Absent slots cost one
    # memoized template lookup and render nothing.
    #
    #   app/views/chats/slots/_inbox_top.html.erb
    #
    # The slots: inbox_top, inbox_empty, conversation_header_actions,
    # locked_composer, message_meta.
    def chats_slot(name, **locals)
      return unless chats_slot?(name)

      render(partial: "chats/slots/#{name}", locals: locals)
    end

    # Whether a slot partial exists. Memoized per view instance, so a slot
    # rendered inside a collection costs ONE lookup per request, not one per
    # row. Anything outside SLOTS is ignored rather than looked up: the slot
    # names are a contract, and a typo should render nothing instead of
    # quietly becoming a new extension point nobody documented.
    def chats_slot?(name)
      key = name.to_s
      return false unless Chats::EngineHelper::SLOTS.include?(key)

      @chats_slots ||= {}
      return @chats_slots[key] if @chats_slots.key?(key)

      @chats_slots[key] = lookup_context.exists?("chats/slots/#{key}", [], true)
    end

    # --- Messager display -----------------------------------------------------

    # Whether block/report affordances apply to this messager. False for
    # `acts_as_messager blockable: false` (a support desk, a bot) — the
    # bundled views hide the affordance instead of asking hosts to branch on
    # class.
    def chats_blockable?(messager)
      Chats.blockable?(messager)
    end

    # A messager's profile URL per `config.messager_url`, or nil.
    def chats_messager_url(messager)
      Chats.messager_url_for(messager)
    end

    # A messager's name, linked to their profile when `config.messager_url`
    # gives one and plain text when it doesn't — so the gem never renders a
    # dead anchor or assumes a `user_path` exists.
    def chats_messager_name(messager, css_class: nil)
      name = Chats.display_name_for(messager)
      url = chats_messager_url(messager)

      url.present? ? link_to(name, url, class: css_class) : tag.span(name, class: css_class)
    end

    # The signature line under a signed message ("— Lucía G."), or nil.
    def chats_message_signature(message)
      Chats.message_signature_for(message)
    end

    # --- Grouped inbox rows ---------------------------------------------------

    # Where a stacked inbox row goes: straight to the thread when the stack
    # holds exactly one conversation, otherwise to the stack itself.
    def chats_group_path(group)
      return chats_routes.conversation_path(group.conversation) if group.single?

      chats_group_path_for(group.messager)
    end

    # The stack list for a messager: the host's `group_path:` callable when
    # `acts_as_messager` declared one (support_desk points it at its own
    # screen), else chats' own filtered inbox.
    def chats_group_path_for(messager)
      custom = messager.class.try(:chat_group_path)
      path = custom&.call(chats_viewer)

      path.presence || chats_routes.conversations_path(with: Chats.inbox_with_sgid(messager))
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

    # Active Storage routes are drawn on the host app, not on this isolated
    # engine. A bare `image_tag variant` is fine in normal host views, but
    # inside engine views it asks the engine route set to polymorphically
    # resolve ActiveStorage::VariantWithRecord and can fall through to
    # `to_model`. Build the same proxy/redirect routes Rails would build,
    # explicitly against the host route set, before `image_tag` sees it.
    def chats_avatar_image_source(source)
      return source unless chats_active_storage_source?(source)

      routes = chats_main_routes

      if source.respond_to?(:variation) && source.respond_to?(:blob)
        routes.rails_representation_url(source, only_path: true)
      elsif source.respond_to?(:blob)
        routes.rails_blob_url(source.blob, only_path: true)
      elsif source.respond_to?(:signed_id) && source.respond_to?(:filename)
        routes.rails_blob_url(source, only_path: true)
      else
        source
      end
    end

    def chats_active_storage_source?(source)
      defined?(ActiveStorage) && source.class.name.start_with?("ActiveStorage::")
    end

    def chats_main_routes
      respond_to?(:main_app) ? main_app : Rails.application.routes.url_helpers
    end
  end
end

# Expose the helpers to the HOST app's views (isolated engines don't share
# helpers automatically). The hook lives HERE, at the bottom of the file that
# defines the constant — not in an engine initializer — so it's
# self-resolving: whenever this file loads (eager load, autoload on first
# use, or the engine's to_prepare touch), the constant already exists by the
# time the hook can possibly run. Registering it from an initializer instead
# would blow up at boot in hosts where ActionView is already loaded during
# initializers (web-console does this) because `include Chats::EngineHelper`
# would fire before the autoloader is ready. Same pattern as the moderate
# gem's report_link helper.
if defined?(ActiveSupport)
  ActiveSupport.on_load(:action_view) do
    include Chats::EngineHelper
  end
end
