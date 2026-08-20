#!/usr/bin/ruby
# frozen_string_literal: true

require "minitest/autorun"
require_relative "parse-ios-screenshot-build-settings"
require_relative "screenshot-test-temp-root"

class ParseIOSScreenshotBuildSettingsTest < Minitest::Test
  def test_selects_named_main_target_even_when_watch_block_comes_first
    source = JSON.generate([
      {
        "target" => "QuakeSignalWatch",
        "action" => "build",
        "buildSettings" => {
          "PRODUCT_BUNDLE_IDENTIFIER" => "com.quakesignal.app.watchkitapp",
          "TARGET_BUILD_DIR" => "/tmp/Watch",
          "WRAPPER_NAME" => "QuakeSignalWatch.app",
        },
      },
      {
        "target" => "QuakeSignal",
        "action" => "build",
        "buildSettings" => exact_settings,
      },
    ])
    parsed = QuakeSignalIOSBuildSettings.parse(source)
    assert_equal "QuakeSignal", parsed.fetch("target")
    assert_equal "#{fixture_root}/Build/Products/Debug-iphonesimulator",
                 parsed.fetch("targetBuildDirectory")
    assert_equal "arm64", parsed.fetch("architectures")
    assert_equal "NO", parsed.fetch("codeSigningRequired")
  end

  def test_rejects_ambiguous_missing_or_wrong_bundle_target
    block = {
      "target" => "QuakeSignal",
      "action" => "build",
      "buildSettings" => exact_settings,
    }
    assert_error(/exactly one/) { QuakeSignalIOSBuildSettings.parse(JSON.generate([block, block])) }
    assert_error(/target build settings are incomplete/) { QuakeSignalIOSBuildSettings.parse("") }
    assert_error(/not QuakeSignal/) do
      wrong = Marshal.load(Marshal.dump(block))
      wrong.fetch("buildSettings")["PRODUCT_BUNDLE_IDENTIFIER"] = "com.example.wrong"
      QuakeSignalIOSBuildSettings.parse(JSON.generate([wrong]))
    end
  end

  private

  def fixture_root
    QuakeSignalScreenshotTestTempRoot.path.join("quakesignal-ios-build-settings-fixture")
  end

  def exact_settings
    root = fixture_root
    {
      "PRODUCT_BUNDLE_IDENTIFIER" => "com.quakesignal.app",
      "TARGET_BUILD_DIR" => "#{root}/Build/Products/Debug-iphonesimulator",
      "WRAPPER_NAME" => "QuakeSignal.app",
      "EXECUTABLE_NAME" => "QuakeSignal",
      "FULL_PRODUCT_NAME" => "QuakeSignal.app",
      "CONFIGURATION" => "Debug",
      "PLATFORM_NAME" => "iphonesimulator",
      "SDK_NAME" => "iphonesimulator26.5",
      "SDKROOT" => "/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator26.5.sdk",
      "ARCHS" => "arm64",
      "ONLY_ACTIVE_ARCH" => "YES",
      "CODE_SIGNING_ALLOWED" => "NO",
      "CODE_SIGNING_REQUIRED" => "NO",
      "CODE_SIGN_IDENTITY" => "",
      "COMPILER_INDEX_STORE_ENABLE" => "NO",
      "BUILD_DIR" => "#{root}/Build/Products",
      "BUILD_ROOT" => "#{root}/Build",
      "CONFIGURATION_BUILD_DIR" => "#{root}/Build/Products/Debug-iphonesimulator",
      "OBJROOT" => "#{root}/Build/Intermediates.noindex",
      "SYMROOT" => "#{root}/Build/Products",
      "SHARED_PRECOMPS_DIR" => "#{root}/SharedPrecompiledHeaders",
      "CLANG_MODULE_CACHE_PATH" => "#{root}/ModuleCache.noindex",
      "DSTROOT" => "#{root}/Dst",
    }
  end

  def assert_error(pattern)
    error = assert_raises(QuakeSignalIOSBuildSettings::Error) { yield }
    assert_match pattern, error.message
  end
end
