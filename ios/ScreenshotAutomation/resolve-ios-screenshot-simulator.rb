#!/usr/bin/ruby
# frozen_string_literal: true

require "json"

module QuakeSignalIOSScreenshotSimulator
  class Error < StandardError; end

  class DuplicateRejectingHash < Hash
    def []=(key, value)
      raise Error, "duplicate simctl JSON key #{key.inspect}" if key?(key)

      super
    end
  end

  module_function

  def resolve(devices_source:, device_types_source:, udid:, expected_runtime:, expected_device_type:, expected_model:,
              expected_name:)
    devices = parse(devices_source, "device inventory").fetch("devices")
    types = parse(device_types_source, "device-type inventory").fetch("devicetypes")
    matches = devices.flat_map do |runtime, records|
      unless runtime.is_a?(String) && records.is_a?(Array)
        raise Error, "simctl device inventory has an unexpected schema"
      end
      records.each_with_object([]) do |record, found|
        found << [runtime, record] if record.fetch("udid", nil) == udid
      end
    end
    raise Error, "expected one observed simulator for UDID #{udid}" unless matches.length == 1

    runtime, device = matches.first
    require_equal(runtime, expected_runtime, "observed simulator runtime")
    require_equal(device.fetch("state"), "Booted", "observed simulator state")
    require_equal(device.fetch("isAvailable", true), true, "observed simulator availability")
    require_equal(device.fetch("name"), expected_name, "observed simulator lease name")
    require_equal(device.fetch("deviceTypeIdentifier"), expected_device_type, "observed simulator device type")
    type_matches = types.select do |record|
      record.is_a?(Hash) && record.fetch("identifier", nil) == expected_device_type
    end
    raise Error, "expected one installed device type #{expected_device_type}" unless type_matches.length == 1

    model = type_matches.first.fetch("name")
    require_equal(model, expected_model, "observed simulator model")
    {
      "runtimeIdentifier" => runtime,
      "deviceTypeIdentifier" => device.fetch("deviceTypeIdentifier"),
      "deviceModel" => model,
      "deviceName" => device.fetch("name"),
      "deviceIdentifier" => device.fetch("udid"),
      "state" => device.fetch("state"),
    }
  rescue KeyError, TypeError => error
    raise Error, "invalid simctl inventory: #{error.message}"
  end

  def parse(source, label)
    value = JSON.parse(source, object_class: DuplicateRejectingHash)
    raise Error, "#{label} must be an object" unless value.is_a?(Hash)

    value
  rescue JSON::ParserError => error
    raise Error, "invalid #{label}: #{error.message}"
  end

  def require_equal(actual, expected, label)
    return if actual == expected

    raise Error, "#{label} mismatch: expected #{expected.inspect}, found #{actual.inspect}"
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    unless ARGV.length == 7
      abort "Usage: resolve-ios-screenshot-simulator.rb <devices.json> <device-types.json> <udid> <expected-runtime> <expected-device-type> <expected-model> <expected-lease-name>"
    end
    devices_path, types_path, udid, runtime, device_type, model, name = ARGV
    result = QuakeSignalIOSScreenshotSimulator.resolve(
      devices_source: File.read(devices_path),
      device_types_source: File.read(types_path),
      udid: udid,
      expected_runtime: runtime,
      expected_device_type: device_type,
      expected_model: model,
      expected_name: name,
    )
    puts JSON.generate(result)
  rescue QuakeSignalIOSScreenshotSimulator::Error, Errno::ENOENT => error
    warn "error: #{error.message}"
    exit 65
  end
end
