#!/usr/bin/ruby
# frozen_string_literal: true

require "json"
require "minitest/autorun"
require_relative "resolve-ios-screenshot-simulator"

class ResolveIOSScreenshotSimulatorTest < Minitest::Test
  RUNTIME = "com.apple.CoreSimulator.SimRuntime.iOS-26-5"
  TYPE = "com.apple.CoreSimulator.SimDeviceType.iPhone-11-Pro-Max"

  def test_resolves_observed_runtime_type_model_and_boot_state
    result = resolve
    assert_equal RUNTIME, result.fetch("runtimeIdentifier")
    assert_equal TYPE, result.fetch("deviceTypeIdentifier")
    assert_equal "iPhone 11 Pro Max", result.fetch("deviceModel")
    assert_equal "reviewed-udid", result.fetch("deviceIdentifier")
    assert_equal "QuakeSignal screenshot simulator", result.fetch("deviceName")
    assert_equal "Booted", result.fetch("state")
  end

  def test_rejects_env_claims_that_disagree_with_observed_simulator
    assert_error(/runtime/) { resolve(expected_runtime: "forged-runtime") }
    assert_error(/device type/) { resolve(expected_device_type: "forged-type") }
    assert_error(/model/) { resolve(expected_model: "Generic Phone") }
    assert_error(/lease name/) { resolve(expected_name: "Forged simulator") }
    assert_error(/state/) { resolve(device_overrides: { "state" => "Shutdown" }) }
    assert_error(/availability/) { resolve(device_overrides: { "isAvailable" => false }) }
  end

  private

  def resolve(
    expected_runtime: RUNTIME,
    expected_device_type: TYPE,
    expected_model: "iPhone 11 Pro Max",
    expected_name: "QuakeSignal screenshot simulator",
    device_overrides: {}
  )
    device = {
      "name" => "QuakeSignal screenshot simulator",
      "udid" => "reviewed-udid",
      "state" => "Booted",
      "isAvailable" => true,
      "deviceTypeIdentifier" => TYPE,
    }.merge(device_overrides)
    QuakeSignalIOSScreenshotSimulator.resolve(
      devices_source: JSON.generate("devices" => { RUNTIME => [device] }),
      device_types_source: JSON.generate(
        "devicetypes" => [{ "name" => "iPhone 11 Pro Max", "identifier" => TYPE }],
      ),
      udid: "reviewed-udid",
      expected_runtime: expected_runtime,
      expected_device_type: expected_device_type,
      expected_model: expected_model,
      expected_name: expected_name,
    )
  end

  def assert_error(pattern)
    error = assert_raises(QuakeSignalIOSScreenshotSimulator::Error) { yield }
    assert_match pattern, error.message
  end
end
