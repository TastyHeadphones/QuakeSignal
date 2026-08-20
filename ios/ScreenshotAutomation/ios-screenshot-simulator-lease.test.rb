#!/usr/bin/ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "pathname"
require "tmpdir"
require_relative "ios-screenshot-simulator-lease"

class IOSScreenshotSimulatorLeaseTest < Minitest::Test
  COMMIT = "a" * 40
  TOKEN = "b" * 32
  UUID = "11111111-2222-3333-4444-555555555555"
  RUNTIME = "com.apple.CoreSimulator.SimRuntime.iOS-26-5"
  TYPE = "com.apple.CoreSimulator.SimDeviceType.iPhone-11-Pro-Max"
  NAME = "QuakeSignal iPhone screenshot set #{TOKEN}"

  def setup
    @temporary_directory = Dir.mktmpdir("quakesignal-ios-simulator-lease-test", temp_parent)
    @root = Pathname.new(@temporary_directory)
    @lease = @root.join("lease.json")
    @specs = [{
      "displayClass" => "iphone-6.5",
      "name" => NAME,
      "runtimeIdentifier" => RUNTIME,
      "deviceTypeIdentifier" => TYPE,
    }]
    QuakeSignalIOSScreenshotSimulatorLease.create(
      path: @lease, source_commit: COMMIT, token: TOKEN, owner_pid: Process.pid, simulators: @specs,
    )
  end

  def teardown
    FileUtils.remove_entry(@temporary_directory) if @temporary_directory && File.exist?(@temporary_directory)
  end

  def test_parent_owned_assignment_resolution_and_absence_completion
    QuakeSignalIOSScreenshotSimulatorLease.assign(
      path: @lease, token: TOKEN, display_class: "iphone-6.5", device_identifier: UUID,
    )
    assert QuakeSignalIOSScreenshotSimulatorLease.verify_reuse(
      path: @lease, source_commit: COMMIT, token: TOKEN, owner_pid: Process.pid,
      display_class: "iphone-6.5", name: NAME, device_identifier: UUID,
      runtime_identifier: RUNTIME, device_type_identifier: TYPE,
    )
    devices = JSON.generate("devices" => { RUNTIME => [{
      "name" => NAME, "udid" => UUID, "deviceTypeIdentifier" => TYPE, "state" => "Shutdown",
    }] })
    assert_equal UUID, QuakeSignalIOSScreenshotSimulatorLease.resolve(
      path: @lease, token: TOKEN, devices_source: devices, display_class: "iphone-6.5",
    )

    retained = @root.join("simulator-lease-evidence.json")
    FileUtils.cp(@lease, retained)
    absence = @root.join("simulator-absence-evidence")
    absence.mkpath
    empty = JSON.pretty_generate("devices" => { RUNTIME => [] }) + "\n"
    absence.join("iphone-6.5-uuid.json").write(empty)
    absence.join("iphone-6.5-name.json").write(empty)
    evidence_path = @root.join("cleanup.json")
    evidence = QuakeSignalIOSScreenshotSimulatorLease.complete(
      path: @lease, token: TOKEN, lease_evidence: retained,
      absence_evidence_directory: absence, evidence_output: evidence_path,
      verified_at: "2026-08-21T00:00:00Z",
    )
    refute @lease.exist?
    assert evidence_path.file?
    assert_equal %w[deviceIdentifier leaseName],
                 evidence.fetch("simulators").first.fetch("absenceQueries").map { |item| item.fetch("kind") }
  end

  def test_rejects_forged_parent_token_or_device
    QuakeSignalIOSScreenshotSimulatorLease.assign(
      path: @lease, token: TOKEN, display_class: "iphone-6.5", device_identifier: UUID,
    )
    assert_error(/active owned record/) do
      QuakeSignalIOSScreenshotSimulatorLease.verify_reuse(
        path: @lease, source_commit: COMMIT, token: "c" * 32, owner_pid: Process.pid,
        display_class: "iphone-6.5", name: NAME, device_identifier: UUID,
        runtime_identifier: RUNTIME, device_type_identifier: TYPE,
      )
    end
    assert_error(/invoking parent/) do
      QuakeSignalIOSScreenshotSimulatorLease.verify_reuse(
        path: @lease, source_commit: COMMIT, token: TOKEN, owner_pid: Process.pid + 1,
        display_class: "iphone-6.5", name: NAME, device_identifier: UUID,
        runtime_identifier: RUNTIME, device_type_identifier: TYPE,
      )
    end
  end

  def test_rejects_nonempty_filtered_absence_snapshot_and_retains_lease
    QuakeSignalIOSScreenshotSimulatorLease.assign(
      path: @lease, token: TOKEN, display_class: "iphone-6.5", device_identifier: UUID,
    )
    retained = @root.join("simulator-lease-evidence.json")
    FileUtils.cp(@lease, retained)
    absence = @root.join("simulator-absence-evidence")
    absence.mkpath
    present = JSON.pretty_generate("devices" => { RUNTIME => [{ "udid" => UUID }] }) + "\n"
    absence.join("iphone-6.5-uuid.json").write(present)
    absence.join("iphone-6.5-name.json").write(JSON.pretty_generate("devices" => { RUNTIME => [] }) + "\n")
    assert_error(/still contains a device/) do
      QuakeSignalIOSScreenshotSimulatorLease.complete(
        path: @lease, token: TOKEN, lease_evidence: retained,
        absence_evidence_directory: absence, evidence_output: @root.join("cleanup.json"),
        verified_at: "2026-08-21T00:00:00Z",
      )
    end
    assert @lease.file?
    refute @root.join("cleanup.json").exist?
  end

  private

  def temp_parent
    Pathname.new(
      ENV["QUAKESIGNAL_TEST_TEMP_ROOT"] || ENV["RUNNER_TEMP"] || ENV["TMPDIR"] || Dir.tmpdir,
    ).realpath.to_s
  end

  def assert_error(pattern)
    error = assert_raises(QuakeSignalIOSScreenshotSimulatorLease::Error) { yield }
    assert_match pattern, error.message
  end
end
