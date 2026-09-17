# frozen_string_literal: true

module Chats
  # Share one sender budget across chat and product-specific HTTP composers.
  # The host owns the cache store. Using its atomic increment also works on
  # Rails 7 and avoids depending on Rails' private controller limiter API.
  module SendRateLimited
    extend ActiveSupport::Concern

    included do
      before_action :enforce_chat_send_rate_limit, only: :create
    end

    private

    def chat_rate_limit_messager
      send(Chats.config.current_messager_method)
    end

    def enforce_chat_send_rate_limit
      limit = Chats.config.send_rate_limit
      return unless limit

      sender = chat_rate_limit_messager&.to_gid&.to_s || request.remote_ip
      count = self.class.cache_store.increment("rate-limit:chats/messages:#{sender}", 1,
                                               expires_in: limit.fetch(:within))
      head :too_many_requests if count && count > limit.fetch(:to)
    end
  end
end
