# frozen_string_literal: true

# Minimal host wiring, exactly what the install generator suggests. Tests
# that exercise other configurations set them per-test (Chats.reset! +
# re-configure in setup/teardown keeps this from leaking).
Chats.configure do |config|
  config.messager_class = "User"
end
