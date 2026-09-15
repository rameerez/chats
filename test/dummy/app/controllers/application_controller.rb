# frozen_string_literal: true

# The dummy host's controller — what Chats::ApplicationController inherits
# from by default (config.parent_controller). Provides the two methods the
# engine's defaults expect (current_user / authenticate_user!) via a plain
# session, so no auth framework is needed to test the full request cycle.
class ApplicationController < ActionController::Base
  helper_method :current_user

  def current_user
    return @current_user if defined?(@current_user)

    @current_user = session[:messager_gid].presence && GlobalID::Locator.locate(session[:messager_gid])
  end

  def authenticate_user!
    head :unauthorized unless current_user
  end
end
