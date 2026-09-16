# frozen_string_literal: true

require "rails/engine"
require "turbo-rails"

module Chats
  # The mountable engine: wires autoloading, migrations, locales, the
  # ActiveRecord macros, importmap pins, asset paths, and boot-time model
  # configuration into the host app.
  class Engine < ::Rails::Engine
    isolate_namespace Chats

    # -------------------------------------------------------------------------
    # Zeitwerk: the gem keeps its ActiveRecord models under lib/chats/models
    # (same layout as the moderate gem) so the whole domain ships in lib/ and
    # the engine's app/ tree only holds the web layer (controllers, helpers,
    # views). For that to autoload correctly we manage the loader by hand:
    #
    #   - `push_dir(lib/chats, namespace: Chats)` makes lib/chats/models/...
    #     autoloadable *under the Chats namespace*.
    #   - `collapse(models)` + `collapse(models/concerns)` mean the files in
    #     those folders define Chats::Conversation / Chats::Messager — not
    #     Chats::Models::Conversation.
    #   - The SPINE files (version/errors/configuration/macros/engine) are
    #     required explicitly by lib/chats.rb at boot, so they must be
    #     *ignored* by the loader or Zeitwerk would complain about double
    #     definitions / unmanaged constants.
    # -------------------------------------------------------------------------
    LIB_ROOT = File.expand_path("..", __dir__)
    CHATS_LIB = File.expand_path("chats", LIB_ROOT)

    ZEITWERK_IGNORED = %w[
      version.rb errors.rb configuration.rb engine.rb macros.rb subscribers.rb
    ].freeze

    initializer "chats.autoload", before: :set_autoload_paths do
      loader = Rails.autoloaders.main

      ZEITWERK_IGNORED.each do |file|
        path = File.join(CHATS_LIB, file)
        loader.ignore(path) if File.exist?(path)
      end

      %w[models models/concerns].each do |dir|
        path = File.join(CHATS_LIB, dir)
        loader.collapse(path) if File.directory?(path)
      end

      loader.push_dir(CHATS_LIB, namespace: Chats)
    end

    config.eager_load_paths << CHATS_LIB

    # Make the gem's migrations runnable from the host without copying
    # (`rails db:migrate` picks them up) — the install generator still copies
    # a host-owned migration, which is the recommended path; this initializer
    # mainly serves the dummy app and hosts that prefer engine-owned
    # migrations.
    initializer "chats.migrations" do |app|
      unless app.root.to_s == root.to_s
        config.paths["db/migrate"].expanded.each do |path|
          app.config.paths["db/migrate"] << path
        end
      end
    end

    # Hand the gem's deprecator to the app, so `config.active_support.
    # deprecation` (and `deprecators.silence`) govern chats' own deprecation
    # warnings like any other framework's.
    initializer "chats.deprecator" do |app|
      app.deprecators[:chats] = Chats.deprecator if app.respond_to?(:deprecators)
    end

    # Expose `acts_as_messager` / `acts_as_chat_subject` on every AR model.
    initializer "chats.active_record" do
      ActiveSupport.on_load(:active_record) do
        extend Chats::Macros
      end
    end

    # The gem's locale files (en, es) ship through Rails::Engine's own
    # :add_locales initializer, which picks up every engine's config/locales
    # automatically — and deliberately NOT through a manual
    # `app.config.i18n.load_path +=` on top of it.
    #
    # That append is not merely redundant, it inverts the contract: railtie
    # paths are unshifted ahead of everything in load_path, so an appended
    # copy lands AFTER the host's own locales and silently overrides them. A
    # host rewording `chats.flashes.blocked` in its own es.yml would keep
    # reading ours, with no error and nothing to see.
    #
    # Gem first, host last. `clickwrap` carries the same note; `support_desk`
    # shipped the bug and measured it (its file sat in load_path 14 times and
    # the host's override lost).

    # NOTE: the host-facing helpers (`chat_button_to`, `chats_unread_badge`, …)
    # are exposed to ActionView from the BOTTOM of engine_helper.rb itself
    # (moderate's proven pattern), NOT from an initializer here: an
    # `on_load(:action_view)` registered during initializers fires
    # IMMEDIATELY in hosts where something (web-console, a mailer preview…)
    # already loaded ActionView — and at that point the autoloader can't
    # resolve Chats::EngineHelper yet (NameError at boot). Keeping the hook
    # in the same file as the constant makes it self-resolving; the
    # `to_prepare` touch below guarantees the file loads on every boot and
    # code reload even before anything references it.

    # -------------------------------------------------------------------------
    # JavaScript: the engine ships tiny Stimulus controllers (thread, composer,
    # debounced-submit, refresh-inbox) with NO build step, pinned for
    # importmap-rails hosts.
    #
    # The pin keys live under "controllers/chats/..." ON PURPOSE: the stock
    # Rails `app/javascript/controllers/index.js` calls
    # `eagerLoadControllersFrom("controllers", application)`, which scans the
    # rendered importmap for keys matching ^controllers/.*_controller$ and
    # registers each one, deriving the identifier from the path
    # ("controllers/chats/thread_controller" → "chats--thread"; see
    # stimulus-rails' stimulus-loading.js, registerControllerFromPath).
    # Result: a host with the default Stimulus setup gets the chats--*
    # controllers REGISTERED AUTOMATICALLY, zero JS changes.
    #
    # We `unshift` (not `<<`) our importmap so the HOST's pins are drawn after
    # ours — importmap-rails resolves duplicate pins last-wins, so a host can
    # override any chats controller by pinning the same key (or just dropping
    # a file at app/javascript/controllers/chats/thread_controller.js, which
    # `pin_all_from "app/javascript/controllers"` then pins over ours).
    # importmap-rails appends the app's own config/importmap.rb inside its
    # "importmap" initializer and draws everything in path order:
    # https://github.com/rails/importmap-rails (lib/importmap/engine.rb)
    # -------------------------------------------------------------------------
    initializer "chats.importmap", before: "importmap" do |app|
      if app.config.respond_to?(:importmap)
        app.config.importmap.paths.unshift(root.join("config/importmap.rb"))
        # Sweep the importmap cache when our JS changes (dev nicety).
        app.config.importmap.cache_sweepers << root.join("app/javascript")
      end
    end

    # Serve the engine's JS + CSS through the host's asset pipeline
    # (propshaft or sprockets — both honor config.assets.paths).
    initializer "chats.assets" do |app|
      if app.config.respond_to?(:assets)
        app.config.assets.paths << root.join("app/javascript")
        app.config.assets.paths << root.join("app/assets/stylesheets")

        # Propshaft serves anything on the load path; Sprockets serves only
        # what is on the precompile list, so a Sprockets host 404s the
        # stylesheet without this line.
        app.config.assets.precompile << "chats.css" if app.config.assets.respond_to?(:precompile)
      end
    end

    # Apply boot-time configuration that has to touch autoloaded classes —
    # runs on every reload in development so it stays applied to fresh ones.
    config.to_prepare do
      # Touch the helper so its bottom-of-file on_load(:action_view) hook
      # registers even if no engine code was referenced yet (see NOTE above).
      # (Assigned to appease Lint/Void — the constant REFERENCE is the point.)
      _loaded = Chats::EngineHelper

      if Chats.config.encrypt_messages && Chats::Message.respond_to?(:encrypts)
        # Opt-in encryption at rest (config.encrypt_messages = true).
        # `deterministic: false` (the default) is correct for free text.
        Chats::Message.encrypts :body
      end
    end
  end
end
