# frozen_string_literal: true

# Test-only login: integration tests POST /test_login with a messager's
# GlobalID to act as that messager (see test_helper's `login_as`). A GID, not
# an id, because ANY acts_as_messager model can be the current messager — a
# User, a Desk, an Organization — and the engine must work for all of them.
class SessionsController < ApplicationController
  def create
    session[:messager_gid] = params[:messager_gid]
    head :no_content
  end

  # A host page (not one of the engine's): what the dock is for.
  def home
    @people = current_user ? User.where.not(id: current_user.id).order(:id).limit(5) : []
  end
end
