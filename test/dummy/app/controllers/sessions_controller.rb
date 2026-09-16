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

  def home
    render plain: "dummy host root"
  end
end
