# frozen_string_literal: true

require "test_helper"

# What `gem build` packages: the gemspec's files come from `git ls-files`,
# so anything tracked ships to every host that installs chats. 0.6.0 shipped
# seven built packages of earlier versions inside itself (3.6 MB).
class GemspecTest < ActiveSupport::TestCase
  SPEC = Gem::Specification.load(File.expand_path("../chats.gemspec", __dir__))

  test "the package holds no built package, tracked or not" do
    assert_empty SPEC.files.grep(/\.gem\z/)
    assert_empty Dir.chdir(File.expand_path("..", __dir__)) { `git ls-files -z '*.gem'`.split("\0") },
                 "a built package is never tracked (.gitignore says *.gem)"
  end

  test "the package holds the engine and none of the test suite" do
    assert_includes SPEC.files, "lib/chats.rb"
    assert_includes SPEC.files, "app/javascript/chats/split_controller.js"
    assert_includes SPEC.files, "app/assets/stylesheets/chats.css"
    assert_empty SPEC.files.grep(%r{\A(test|bin|\.github)/})
  end

  test "the package holds nothing from docs/: not the README's screenshots, not the design notes" do
    assert_empty SPEC.files.grep(%r{\Adocs/}), "GitHub serves those; the gem never reads them"
    assert_empty SPEC.files.grep(/\.(png|jpe?g|gif|webp)\z/)
  end

  test "the README loads its screenshots from the repository, not from the package" do
    readme = File.read(File.expand_path("../README.md", __dir__))

    assert_empty readme.scan(%r{(?<![/\w])docs/screenshots/\S+}),
                 "a relative image path renders on GitHub only; rubygems.org shows a broken image"
  end

  test "the package stays small: code, views and locales" do
    root = File.expand_path("..", __dir__)
    bytes = SPEC.files.sum { |file| File.size(File.join(root, file)) }

    assert_operator bytes, :<, 1024 * 1024, "#{bytes} bytes before compression: what is in there?"
  end
end
