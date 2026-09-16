# frozen_string_literal: true

require "test_helper"

# The badge's default colour is a promise, not a taste. It is a MEANINGFUL
# graphic — it tells someone an account is official — so WCAG 2.1 SC 1.4.11
# (Non-text Contrast) asks for at least 3:1 against whatever it sits on.
#
# This is a real trap and it already caught one value: the familiar #1d9bf0
# is 3.00:1 on --chats-bg but 2.73:1 on --chats-surface, and --chats-surface
# is the inbox row's HOVER background — so the mark would have dropped below
# the bar exactly while someone was pointing at it. Nobody eyeballing a
# swatch on white would have seen that.
class VerifiedBadgeContrastTest < ActiveSupport::TestCase
  STYLESHEET = File.expand_path("../app/assets/stylesheets/chats.css", __dir__)

  # Every ground the badge is rendered against by the bundled views: the page,
  # the row hover, and the two shades a host inverting the palette would pick.
  # The dark pair is not shipped (the gem has one palette), but the default
  # must survive a host flipping it, or "override --chats-verified" becomes a
  # step every dark host has to be told about.
  DARK_GROUNDS = %w[#111827 #0b0f19].freeze

  MINIMUM = 3.0

  test "the badge colour clears 3:1 on every ground the bundled views put it on" do
    badge = css_variable("--chats-verified")
    grounds = { "--chats-bg" => css_variable("--chats-bg"),
                "--chats-surface" => css_variable("--chats-surface") }

    grounds.each do |name, ground|
      actual = contrast_ratio(badge, ground)
      assert actual >= MINIMUM,
             "#{badge} on #{name} (#{ground}) is #{actual}:1, below the #{MINIMUM}:1 " \
             "WCAG 1.4.11 needs for a meaningful graphic"
    end
  end

  test "the badge colour survives a host inverting the palette" do
    badge = css_variable("--chats-verified")

    DARK_GROUNDS.each do |ground|
      actual = contrast_ratio(badge, ground)
      assert actual >= MINIMUM,
             "#{badge} on a dark ground (#{ground}) is #{actual}:1 — pick a default that works " \
             "in both directions, or dark hosts inherit an illegible badge"
    end
  end

  test "the badge inherits its colour, so overriding the variable is enough" do
    css = File.read(STYLESHEET)
    rule = css[/\.chats-verified \{.*?\}/m]

    assert_includes rule, "color: var(--chats-verified)"
    assert_includes css[/\.chats-verified__glyph \{.*?\}/m].to_s, "width"
    assert_includes File.read(File.expand_path("../app/views/chats/shared/_verified_badge.html.erb", __dir__)),
                    'fill="currentColor"',
                    "a hard-coded fill would ignore --chats-verified entirely"
  end

  private

  def css_variable(name)
    value = File.read(STYLESHEET)[/^\s*#{Regexp.escape(name)}:\s*(#[0-9a-fA-F]{6})\s*;/, 1]
    assert value, "#{name} is not declared as a 6-digit hex in chats.css"
    value
  end

  # WCAG 2.1 relative luminance.
  def relative_luminance(hex)
    channels = hex.delete("#").scan(/../).map do |pair|
      c = pair.to_i(16) / 255.0
      c <= 0.03928 ? c / 12.92 : (((c + 0.055) / 1.055)**2.4)
    end

    (0.2126 * channels[0]) + (0.7152 * channels[1]) + (0.0722 * channels[2])
  end

  def contrast_ratio(one, other)
    luminances = [relative_luminance(one), relative_luminance(other)]
    ((luminances.max + 0.05) / (luminances.min + 0.05)).round(2)
  end
end
