# frozen_string_literal: true

# The dummy app's test environment exists for one reason: a gem's suite must
# not write 80 MB of logs onto a contributor's disk. Rails rotates the test
# log at `config.log_file_size`, and a rotated `test.log.0` is how a 100 MB
# blob once reached this repository's history.
#
# Set VERBOSE_TEST_LOG=1 to get the full debug log back for one run.
Rails.application.configure do
  if ENV["VERBOSE_TEST_LOG"].present?
    config.log_level = :debug
  else
    # IO::NULL rather than a log level alone: a level only silences the
    # framework, while the null device also swallows anything the gem or a
    # host writes straight to Rails.logger.
    config.logger = ActiveSupport::Logger.new(IO::NULL)
    config.log_level = :error
  end

  config.active_record.verbose_query_logs = false
  config.active_job.verbose_enqueue_logs = false

  # Rescuable exceptions (RecordNotFound → 404) still render, which the
  # not_found assertions in the integration suite rely on; everything else
  # raises with a real backtrace instead of a 500 page nobody reads.
  config.action_dispatch.show_exceptions = :rescuable
end
