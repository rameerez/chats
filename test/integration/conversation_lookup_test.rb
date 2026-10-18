# frozen_string_literal: true

require "test_helper"

# Chats::ApplicationController#conversation_lookup_scopes: the one extension
# point for a conversation that must open although the inbox hides it (a
# product gem's own records — support_desk's tickets — that a host's
# inbox_scope keeps out of the inbox).
#
# Prepended the way a product gem does it. Inert unless a test hands it a
# scope, so the rest of the suite runs through the default lookup.
module ExtraLookupScope
  class << self
    attr_accessor :scope_for
  end

  protected

  def conversation_lookup_scopes
    extra = ExtraLookupScope.scope_for&.call(chats_current_messager)
    extra ? super + [extra] : super
  end
end
Chats::ApplicationController.prepend(ExtraLookupScope)

class ConversationLookupTest < ActionDispatch::IntegrationTest
  setup do
    @alice = create_user(name: "Alice")
    @bob = create_user(name: "Bob")
    @carol = create_user(name: "Carol")
    @ticket = conversation_between(@alice, @bob, about: create_listing(title: "Ticket 42"))
    @bob.message!(@ticket, "We are on it")
    # The host keeps conversations about a subject out of the inbox (its
    # product shows them elsewhere).
    Chats.config.inbox_scope = ->(relation, _viewer) { relation.where(subject_id: nil) }
  end

  teardown do
    ExtraLookupScope.scope_for = nil
  end

  test "by default, a conversation the inbox hides doesn't open" do
    login_as @alice

    get "/messages/#{@ticket.id}"

    assert_response :not_found
  end

  test "a scope a product appends makes its own scoped-out conversation open, everywhere the engine looks" do
    ExtraLookupScope.scope_for = ->(viewer) { Chats::Conversation.inbox_for(viewer).where.not(subject_id: nil) }
    login_as @alice

    get "/messages/#{@ticket.id}"
    assert_response :success
    assert_includes response.body, "We are on it"

    post "/messages/#{@ticket.id}/messages", params: { message: { body: "Thanks!" } }
    assert_equal "Thanks!", @ticket.messages.order(:id).last.body, "sending looks it up the same way"

    get "/messages/#{@ticket.id}", params: { window: 1 },
                                   headers: { "Turbo-Frame" => "window_conversation_#{@ticket.id}" }
    assert_response :success, "and so does a dock window"

    get "/messages"
    assert_not_includes response.body, "/messages/#{@ticket.id}\"", "it opens; it is still not LISTED"
  end

  test "nothing outside the scopes becomes reachable, and an unknown id is the same 404" do
    ExtraLookupScope.scope_for = ->(viewer) { Chats::Conversation.inbox_for(viewer).where.not(subject_id: nil) }
    outsider = conversation_between(@bob, @carol, about: create_listing(title: "Not Alice's"))
    login_as @alice

    get "/messages/#{outsider.id}"
    assert_response :not_found, "another pair's conversation is in no scope of Alice's"

    get "/messages/0"
    assert_response :not_found

    post "/messages/#{outsider.id}/messages", params: { message: { body: "hi" } }
    assert_response :not_found
  end

  test "the first scope that has it wins; later ones are asked only on a miss" do
    asked = []
    ExtraLookupScope.scope_for = lambda do |_viewer|
      Object.new.tap { |scope| scope.define_singleton_method(:find_by) { |**args| asked << args && nil } }
    end
    login_as @alice
    listed = conversation_between(@alice, @carol)

    get "/messages/#{listed.id}"
    assert_response :success
    assert_empty asked, "the inbox had it: the product's scope was never asked"

    get "/messages/#{@ticket.id}"
    assert_response :not_found
    assert_equal [{ id: @ticket.id.to_s }], asked, "a miss asks the next scope, once"
  end

  test "an error inside a scope is not rescued into a 404" do
    ExtraLookupScope.scope_for = lambda do |_viewer|
      Object.new.tap { |scope| scope.define_singleton_method(:find_by) { |**| raise "the product's scope is broken" } }
    end
    login_as @alice

    error = assert_raises(RuntimeError) { get "/messages/#{@ticket.id}" }
    assert_equal "the product's scope is broken", error.message
  end
end
