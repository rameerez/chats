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
    # The browser tests try the dock's options (`?dock_windows=4`).
    @dock_options = {}
    @dock_options[:windows] = params[:dock_windows].to_i if params[:dock_windows].present?
    @dock_options[:launcher] = false if params[:dock_launcher] == "0"
  end

  # What the message_menu fixture's Pin posts to: back home, saying so. With
  # forgery protection on (one browser test turns it on), reaching this at
  # all proves the cloned form's token was accepted.
  def pin
    redirect_to "/?pinned=#{params[:id].to_i}", status: :see_other
  end

  # Any status, for the browser tests of a window whose load fails.
  def status
    head params[:status].to_i
  end

  # What the tray's help item's frame loads when the `dock_tray_frame` cookie
  # names it: a thread of its own, for the tests of a visit that renders the
  # same frame or another one.
  def tray_frame
    name = params[:name].to_s.gsub(/[^a-z0-9]/i, "")
    render html: helpers.turbo_frame_tag("dummy_help_frame") {
      helpers.safe_join([helpers.tag.p("Thread #{name}", class: "dummy-thread"),
                         helpers.text_area_tag(:dummy_reply, nil, id: "dummy_help_reply")])
    }
  end

  # The same page in a layout that wraps the dock in a shell element.
  def wrapped
    home
    render :home, layout: "wrapped"
  end
end
