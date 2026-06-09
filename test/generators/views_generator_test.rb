# frozen_string_literal: true

require "test_helper"
require "rails/generators/test_case"
require "generators/chats/views_generator"

class ViewsGeneratorTest < Rails::Generators::TestCase
  tests Chats::Generators::ViewsGenerator
  destination File.expand_path("../../tmp/generators", __dir__)
  setup :prepare_destination

  test "ejects every overridable view group by default" do
    run_generator

    assert_file "app/views/chats/conversations/index.html.erb"
    assert_file "app/views/chats/conversations/show.html.erb"
    assert_file "app/views/chats/conversations/_conversation_row.html.erb"
    assert_file "app/views/chats/messages/_message.html.erb"
    assert_file "app/views/chats/messages/_composer.html.erb"
    assert_file "app/views/chats/shared/_unread_badge.html.erb"
  end

  test "can eject a single group" do
    run_generator %w[--views messages]

    assert_file "app/views/chats/messages/_message.html.erb"
    assert_no_file "app/views/chats/conversations/index.html.erb"
  end
end
