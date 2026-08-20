# frozen_string_literal: true

require "pathname"
require "tmpdir"

module QuakeSignalScreenshotTestTempRoot
  ENVIRONMENT_VARIABLES = %w[
    QUAKESIGNAL_TEST_TEMP_ROOT
    RUNNER_TEMP
    TMPDIR
  ].freeze

  module_function

  def path
    selected = ENVIRONMENT_VARIABLES.lazy.map { |name| ENV[name] }.find { |value| !value.nil? }
    raise ArgumentError, "screenshot test temporary parent must not be empty" if selected == ""

    candidate = Pathname.new(selected || Dir.tmpdir).expand_path
    raise ArgumentError, "screenshot test temporary parent is not an existing directory: #{candidate}" unless candidate.directory?

    canonical = candidate.realpath
    raise ArgumentError, "screenshot test temporary parent is not a plain directory: #{canonical}" unless canonical.lstat.directory?

    canonical
  rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP => error
    raise ArgumentError, "screenshot test temporary parent is unavailable: #{candidate || selected}: #{error.message}"
  end
end
