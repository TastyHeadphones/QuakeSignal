#!/usr/bin/ruby
# frozen_string_literal: true

require "json"
require "pathname"

module QuakeSignalIOSBuildSettings
  class Error < StandardError; end

  module_function

  def parse(source, target: "QuakeSignal")
    records = JSON.parse(source, object_class: DuplicateRejectingHash)
    unless records.is_a?(Array)
      raise Error, "xcodebuild JSON must contain an array"
    end
    matches = records.select do |record|
      record.is_a?(Hash) && record.fetch("target", nil) == target
    end
    raise Error, "expected exactly one build-settings record for target #{target}" unless matches.length == 1

    record = matches.first
    unless record.keys.sort == %w[action buildSettings target].sort &&
           record.fetch("action") == "build" && record.fetch("buildSettings").is_a?(Hash)
      raise Error, "target build-settings record has an unexpected schema"
    end
    values = record.fetch("buildSettings")
    result = {
      "target" => target,
      "targetBuildDirectory" => values.fetch("TARGET_BUILD_DIR"),
      "wrapperName" => values.fetch("WRAPPER_NAME"),
      "executableName" => values.fetch("EXECUTABLE_NAME"),
      "fullProductName" => values.fetch("FULL_PRODUCT_NAME"),
      "productBundleIdentifier" => values.fetch("PRODUCT_BUNDLE_IDENTIFIER"),
      "configuration" => values.fetch("CONFIGURATION"),
      "platformName" => values.fetch("PLATFORM_NAME"),
      "sdkName" => values.fetch("SDK_NAME"),
      "sdkRoot" => values.fetch("SDKROOT"),
      "architectures" => values.fetch("ARCHS"),
      "onlyActiveArchitecture" => values.fetch("ONLY_ACTIVE_ARCH"),
      "codeSigningAllowed" => values.fetch("CODE_SIGNING_ALLOWED"),
      "codeSigningRequired" => values.fetch("CODE_SIGNING_REQUIRED"),
      "codeSignIdentity" => values.fetch("CODE_SIGN_IDENTITY"),
      "indexStoreEnabled" => values.fetch("COMPILER_INDEX_STORE_ENABLE"),
      "buildDirectory" => values.fetch("BUILD_DIR"),
      "buildRoot" => values.fetch("BUILD_ROOT"),
      "configurationBuildDirectory" => values.fetch("CONFIGURATION_BUILD_DIR"),
      "objectRoot" => values.fetch("OBJROOT"),
      "symbolRoot" => values.fetch("SYMROOT"),
      "sharedPrecompiledHeadersDirectory" => values.fetch("SHARED_PRECOMPS_DIR"),
      "moduleCacheDirectory" => values.fetch("CLANG_MODULE_CACHE_PATH"),
      "destinationRoot" => values.fetch("DSTROOT"),
    }
    result.reject { |key, _value| key == "codeSignIdentity" }.each do |key, value|
      raise Error, "#{key} is empty" unless value.is_a?(String) && !value.empty?
    end
    unless result.fetch("productBundleIdentifier") == "com.quakesignal.app"
      raise Error, "build-settings target bundle identifier is not QuakeSignal"
    end
    exact_identity = {
      "wrapperName" => "QuakeSignal.app",
      "executableName" => "QuakeSignal",
      "fullProductName" => "QuakeSignal.app",
      "configuration" => "Debug",
      "platformName" => "iphonesimulator",
    }
    exact_identity.each do |key, value|
      unless result.fetch(key) == value
        raise Error, "build-settings #{key} is not the exact QuakeSignal simulator value"
      end
    end
    unless result.fetch("sdkName").match?(/\Aiphonesimulator[^\s]*\z/)
      raise Error, "build-settings SDK_NAME is not iphonesimulator"
    end
    unless %w[arm64 x86_64].include?(result.fetch("architectures"))
      raise Error, "build-settings architectures is not one exact supported host architecture"
    end
    expected_flags = {
      "onlyActiveArchitecture" => "YES",
      "codeSigningAllowed" => "NO",
      "codeSigningRequired" => "NO",
      "codeSignIdentity" => "",
      "indexStoreEnabled" => "NO",
    }
    expected_flags.each do |key, value|
      unless result.fetch(key) == value
        raise Error, "build-settings #{key} is not the exact credential-free screenshot value"
      end
    end
    validate_containment(result)
    result
  rescue JSON::ParserError, KeyError => error
    raise Error, "target build settings are incomplete: #{error.message}"
  end


  def validate_containment(result)
    build_directory = File.expand_path(result.fetch("buildDirectory"))
    derived_root = File.dirname(File.dirname(build_directory))
    expected_paths = {
      "buildDirectory" => File.join(derived_root, "Build/Products"),
      "buildRoot" => File.join(derived_root, "Build"),
      "configurationBuildDirectory" => File.join(derived_root, "Build/Products/Debug-iphonesimulator"),
      "objectRoot" => File.join(derived_root, "Build/Intermediates.noindex"),
      "symbolRoot" => File.join(derived_root, "Build/Products"),
      "sharedPrecompiledHeadersDirectory" => File.join(derived_root, "SharedPrecompiledHeaders"),
      "moduleCacheDirectory" => File.join(derived_root, "ModuleCache.noindex"),
      "destinationRoot" => File.join(derived_root, "Dst"),
      "targetBuildDirectory" => File.join(derived_root, "Build/Products/Debug-iphonesimulator"),
    }
    unless Pathname.new(derived_root).absolute?
      raise Error, "build-settings containment root must be absolute"
    end
    expected_paths.each do |key, expected|
      unless File.expand_path(result.fetch(key)) == expected
        raise Error, "build-settings #{key} escaped the unique screenshot DerivedData root"
      end
    end
    unless result.fetch("sdkRoot").include?("iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator") &&
           result.fetch("sdkRoot").end_with?(".sdk")
      raise Error, "build-settings SDKROOT is not an iPhone Simulator SDK"
    end
  end

  class DuplicateRejectingHash < Hash
    def []=(key, value)
      raise Error, "duplicate build-settings JSON key #{key.inspect}" if key?(key)

      super
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    unless ARGV.empty?
      abort "Usage: parse-ios-screenshot-build-settings.rb < xcodebuild-showBuildSettings.txt"
    end
    puts JSON.generate(QuakeSignalIOSBuildSettings.parse(STDIN.read))
  rescue QuakeSignalIOSBuildSettings::Error => error
    warn "error: #{error.message}"
    exit 65
  end
end
