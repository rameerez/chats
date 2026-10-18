# frozen_string_literal: true

require "test_helper"

# Both search forms are search landmarks (role="search"), so a screen
# reader's landmark navigation finds them. `form_with` drops HTML
# attributes it doesn't know unless they go through `html:`, which is how
# `role: "search"` silently rendered nothing on both.
class SearchLandmarkTest < ActionDispatch::IntegrationTest
  setup do
    @alice = create_user(name: "Alice")
    login_as @alice
  end

  test "the inbox's search form is a search landmark" do
    get "/messages"

    assert_select "form.chats-search[role='search'][data-turbo-frame='chats_inbox_results']", 1
  end

  test "the dock's search form is a search landmark" do
    get "/"

    assert_select ".chats-dock form.chats-dock__search[role='search'][data-turbo-frame='chats_dock_list']", 1
  end

  test "neither is a landmark when search is off" do
    Chats.config.search = false

    get "/messages"
    assert_select "form[role='search']", 0
    get "/"
    assert_select "form[role='search']", 0
  end
end
