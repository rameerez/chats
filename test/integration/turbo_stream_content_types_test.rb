# frozen_string_literal: true

require "test_helper"

# Every endpoint that answers with a Turbo Stream must SAY it answers with
# one. A body full of <turbo-stream> served as text/html is not a stream to
# anything that checks the content type, and the failure is silent — which is
# how `render html: … content_type:` (which forces text/html and ignores the
# option) survived in the thread's missed-broadcast recovery path.
class TurboStreamContentTypesTest < ActionDispatch::IntegrationTest
  TURBO_STREAM = "text/vnd.turbo-stream.html"

  setup do
    @alice = create_user(name: "Alice")
    @bob = create_user(name: "Bob")
    @listing = create_listing(title: "Madrid → Barcelona")
    @conversation = @alice.chat_with(@bob, about: @listing)
    login_as @alice
  end

  test "sending, failing to send, editing, deleting and reacting all answer as streams" do
    message = @alice.message!(@conversation, "hello")

    post "/messages/#{@conversation.id}/messages", params: { message: { body: "hi" } }, as: :turbo_stream
    assert_response :success
    assert_stream_response

    post "/messages/#{@conversation.id}/messages", params: { message: { body: "" } }, as: :turbo_stream
    assert_response :unprocessable_entity
    assert_stream_response

    get "/messages/#{@conversation.id}/messages/#{message.id}", as: :turbo_stream
    assert_response :success
    assert_stream_response

    patch "/messages/#{@conversation.id}/messages/#{message.id}",
          params: { message: { body: "hello (fixed)" } }, as: :turbo_stream
    assert_response :success
    assert_stream_response

    post "/messages/#{@conversation.id}/messages/#{message.id}/reactions",
         params: { emoji: "👍" }, as: :turbo_stream
    assert_response :success
    assert_stream_response

    delete "/messages/#{@conversation.id}/messages/#{message.id}", as: :turbo_stream
    assert_response :success
    assert_stream_response
  end

  test "the locked refusals answer as streams" do
    message = @alice.message!(@conversation, "before the lock")
    @listing.update!(locked: true)

    post "/messages/#{@conversation.id}/messages", params: { message: { body: "nope" } }, as: :turbo_stream
    assert_response :unprocessable_entity
    assert_stream_response

    delete "/messages/#{@conversation.id}/messages/#{message.id}", as: :turbo_stream
    assert_response :unprocessable_entity
    assert_stream_response

    post "/messages/#{@conversation.id}/messages/#{message.id}/reactions",
         params: { emoji: "👍" }, as: :turbo_stream
    assert_response :unprocessable_entity
    assert_stream_response
  end

  test "both thread catch-up responses answer as streams" do
    anchor = @bob.message!(@conversation, "anchor")
    cursor = (anchor.created_at.to_f * 1000).ceil
    @bob.message!(@conversation, "while you were away")

    # The surgical path (a template rendered with formats: :turbo_stream)…
    get "/messages/#{@conversation.id}/refresh", params: { since: cursor },
                                                 headers: { "Accept" => TURBO_STREAM }
    assert_response :success
    assert_stream_response
    assert_includes response.body, "while you were away"

    # …and the deep-backlog path, which answers with a page refresh.
    (Chats.config.messages_per_page + 1).times { |index| @bob.message!(@conversation, "burst #{index}") }
    get "/messages/#{@conversation.id}/refresh", params: { since: cursor },
                                                 headers: { "Accept" => TURBO_STREAM }
    assert_response :success
    assert_stream_response
    assert_includes response.body, %(<turbo-stream action="refresh">)
    assert_not_includes response.body, "request-id", "the client must never skip its own catch-up refresh"
  end

  private

  def assert_stream_response
    assert_equal TURBO_STREAM, response.media_type,
                 "#{request.method} #{request.path} answered #{response.media_type}"
  end
end
