#!/usr/bin/env ruby
# frozen_string_literal: true

# Deterministic structural validation for the local App Store listing kits.
# This intentionally checks only committed metadata and image properties; it
# does not render the app, contact App Store Connect, or modify any asset.

require "json"
require "digest"
require "open3"
require "pathname"
require "rexml/document"
require "rexml/xpath"
require "set"
require "time"
require_relative "verify-apple-screenshot-release-set"

class StoreAssetValidator
  MAX_DESCRIPTION_CHARACTERS = 4000
  MAX_WHATS_NEW_CHARACTERS = 4000
  MAX_PROMOTIONAL_TEXT_CHARACTERS = 170
  MAX_SUBTITLE_CHARACTERS = 30
  MAX_KEYWORD_BYTES = 100

  def initialize
    @errors = []
  end

  def require_nonempty_file(path)
    return if path.file? && path.size.positive?

    error("missing or empty file: #{path}")
  end

  # Store review material is deliberately version controlled alongside the
  # listing copy. A merely present placeholder is not enough: keep a small,
  # stable set of anchors so an accidental replacement cannot silently drop
  # the reviewer route or the published-terms content-rights gate.
  def validate_submission_document(path, document_name, required_phrases)
    require_nonempty_file(path)
    return unless path.file? && path.size.positive?

    text = path.read(encoding: "UTF-8")
    required_phrases.each do |phrase|
      next if text.include?(phrase)

      error("#{path}: #{document_name} must include #{phrase.inspect}")
    end
  end

  # A release-ready checklist may legitimately have every item checked. Check
  # that the Content Rights/Wolfx published-terms review remains a real
  # checkbox item without requiring a particular completion state or bolding.
  def validate_submission_checklist(path, document_name)
    validate_submission_document(path, document_name, ["Content Rights", "Wolfx"])
    return unless path.file? && path.size.positive?

    text = path.read(encoding: "UTF-8")
    return if text.match?(/^- \[[ xX]\].*?\bContent Rights\b.*?\bWolfx\b/m)

    error("#{path}: #{document_name} must contain a Content Rights/Wolfx checkbox item")
  end

  def listing_text(path)
    require_nonempty_file(path)
    return "" unless path.file?

    # A trailing newline is conventional in a repository text file but is not
    # product-page copy. Preserve all meaningful embedded line breaks, which
    # App Store Connect does count in descriptions.
    path.read(encoding: "UTF-8").sub(/\r?\n\z/, "")
  end

  def validate_character_limit(path, text, limit, field)
    return if text.length <= limit

    error("#{path}: #{field} must be at most #{limit} characters (found #{text.length})")
  end

  def validate_keywords(path, text)
    if text.bytesize > MAX_KEYWORD_BYTES
      error("#{path}: keywords must be at most #{MAX_KEYWORD_BYTES} bytes (found #{text.bytesize})")
    end

    terms = text.split(",", -1).map(&:strip)
    if terms.empty? || terms.any?(&:empty?)
      error("#{path}: keywords must be a comma-separated list with no empty terms")
      return
    end

    short_terms = terms.select { |term| term.length <= 2 }
    unless short_terms.empty?
      error("#{path}: every keyword must contain more than two characters (too short: #{short_terms.join(', ')})")
    end
  end

  def validate_listing_copy(directory, require_subtitle: false, require_whats_new: false)
    description = listing_text(directory.join("description.txt"))
    promotional_text = listing_text(directory.join("promotional_text.txt"))
    keywords_path = directory.join("keywords.txt")
    keywords = listing_text(keywords_path)

    validate_character_limit(
      directory.join("description.txt"),
      description,
      MAX_DESCRIPTION_CHARACTERS,
      "description",
    )
    validate_character_limit(
      directory.join("promotional_text.txt"),
      promotional_text,
      MAX_PROMOTIONAL_TEXT_CHARACTERS,
      "promotional text",
    )
    validate_keywords(keywords_path, keywords)

    if require_whats_new
      whats_new_path = directory.join("whats_new_v1.1.txt")
      whats_new = listing_text(whats_new_path)
      if whats_new_path.file? && whats_new_path.size.positive? && whats_new.strip.empty?
        error("#{whats_new_path}: What's New must not be blank")
      end
      validate_character_limit(
        whats_new_path,
        whats_new,
        MAX_WHATS_NEW_CHARACTERS,
        "What's New",
      )
    end

    return unless require_subtitle

    subtitle_path = directory.join("subtitle.txt")
    subtitle = listing_text(subtitle_path)
    validate_character_limit(
      subtitle_path,
      subtitle,
      MAX_SUBTITLE_CHARACTERS,
      "subtitle",
    )
  end

  def validate_ios_listing_copy(directory)
    validate_listing_copy(directory, require_subtitle: true, require_whats_new: true)
  end

  def validate_platform_listing_copy(directory)
    validate_listing_copy(directory)
  end

  def validate_macos_listing_copy(directory)
    description = listing_text(directory.join("description.txt"))
    promotional_text = listing_text(directory.join("promotional_text.txt"))
    subtitle = listing_text(directory.join("subtitle.txt"))
    keywords_path = directory.join("keywords.txt")
    keywords = listing_text(keywords_path)

    validate_character_limit(
      directory.join("description.txt"),
      description,
      MAX_DESCRIPTION_CHARACTERS,
      "description",
    )
    validate_character_limit(
      directory.join("promotional_text.txt"),
      promotional_text,
      MAX_PROMOTIONAL_TEXT_CHARACTERS,
      "promotional text",
    )
    validate_character_limit(
      directory.join("subtitle.txt"),
      subtitle,
      MAX_SUBTITLE_CHARACTERS,
      "subtitle",
    )
    validate_keywords(keywords_path, keywords)
  end

  def validate_image(path, formats:, dimensions:)
    unless path.file?
      error("missing screenshot: #{path}")
      return
    end

    properties = sips_properties(path)
    return unless properties

    format = properties.fetch("format", "").downcase
    error("#{path}: expected #{formats.join(' or ')}, found #{format.inspect}") unless formats.include?(format)

    width = integer_or_nil(properties.fetch("pixelWidth", ""))
    height = integer_or_nil(properties.fetch("pixelHeight", ""))
    unless dimensions.include?([width, height])
      expected = dimensions.map { |item| item.join("x") }.join(", ")
      error("#{path}: expected #{expected} pixels, found #{width}x#{height}")
    end

    alpha = properties.fetch("hasAlpha", "").downcase
    error("#{path}: screenshots must be opaque (hasAlpha: #{alpha.inspect})") unless alpha == "no"
  end

  def error(message)
    @errors << message
  end

  def finish!
    return if @errors.empty?

    warn "Store listing asset validation failed:"
    @errors.each { |message| warn "- #{message}" }
    exit 1
  end

  private

  def sips_properties(path)
    output, status = Open3.capture2e(
      "sips", "-g", "pixelWidth", "-g", "pixelHeight", "-g", "format", "-g", "hasAlpha", path.to_s,
    )
    unless status.success?
      error("could not inspect #{path}: #{output.strip}")
      return nil
    end

    output.each_line.each_with_object({}) do |line, properties|
      match = line.match(/^\s*(pixelWidth|pixelHeight|format|hasAlpha):\s*(.+?)\s*$/)
      properties[match[1]] = match[2] if match
    end
  end

  def integer_or_nil(value)
    Integer(value)
  rescue ArgumentError
    nil
  end
end

WATCH_ICON_SHA256 = "b792fccc4c08645fb6485ab96c1882c069229246162b02ebdbb605157a5bc65f"
WATCH_ICON_SOURCE_SHA256 = "e0817684601e3a2e7b0581ec1810ed2d95293a23ee8ed97b1d5303803aaa0321"
WATCH_ICON_MAX_FOREGROUND_RADIUS = 384.0

def validate_watch_app_icon_contract!(root)
  root = Pathname.new(root).realpath
  catalog = root.join("ios/QuakeSignalWatch/Assets.xcassets/WatchAppIcon.appiconset")
  contents_path = catalog.join("Contents.json")
  icon_path = catalog.join("watch-icon-1024.png")
  ios_icon_path = root.join("ios/QuakeSignal/Assets.xcassets/AppIcon.appiconset/icon-1024.png")
  source_path = root.join("assets/app-icon.svg")

  expected_contents = {
    "images" => [
      {
        "filename" => "watch-icon-1024.png",
        "idiom" => "universal",
        "platform" => "watchos",
        "size" => "1024x1024",
      },
    ],
    "info" => { "author" => "xcode", "version" => 1 },
  }
  contents = JSON.parse(contents_path.read(encoding: "UTF-8"))
  raise "Watch app icon catalog schema drifted" unless contents == expected_contents

  project_source = root.join("ios/project.yml").read(encoding: "UTF-8")
  watch_target = project_source[/^  QuakeSignalWatch:\n.*?(?=^  \S|\z)/m]
  unless watch_target&.include?("ASSETCATALOG_COMPILER_APPICON_NAME: WatchAppIcon")
    raise "Watch target must select the reviewed WatchAppIcon catalog"
  end

  raise "Watch app icon file digest drifted" unless Digest::SHA256.file(icon_path).hexdigest == WATCH_ICON_SHA256
  raise "canonical app icon source digest drifted" unless Digest::SHA256.file(source_path).hexdigest == WATCH_ICON_SOURCE_SHA256
  unless Digest::SHA256.file(ios_icon_path).hexdigest == WATCH_ICON_SHA256
    raise "reviewed shared iOS/Watch icon artwork drifted"
  end

  output, status = Open3.capture2e("sips", "-g", "all", icon_path.to_s)
  raise "could not inspect Watch app icon: #{output.strip}" unless status.success?

  properties = output.each_line.each_with_object({}) do |line, values|
    match = line.match(/^\s*([A-Za-z][A-Za-z0-9]+):\s*(.+?)\s*$/)
    values[match[1]] = match[2] if match
  end
  expected_properties = {
    "pixelWidth" => "1024",
    "pixelHeight" => "1024",
    "format" => "png",
    "samplesPerPixel" => "3",
    "bitsPerSample" => "8",
    "hasAlpha" => "no",
    "space" => "RGB",
    "profile" => "sRGB IEC61966-2.1",
  }
  expected_properties.each do |key, expected|
    actual = properties[key]
    raise "Watch app icon #{key} must be #{expected.inspect}, found #{actual.inspect}" unless actual == expected
  end

  document = REXML::Document.new(source_path.read(encoding: "UTF-8"))
  svg = document.root
  raise "canonical app icon SVG canvas drifted" unless svg&.attributes&.[]("viewBox") == "0 0 1024 1024"

  gradient = REXML::XPath.first(document, "//*[local-name()='linearGradient' and @id='brand']")
  stops = REXML::XPath.match(gradient, "*[local-name()='stop']").map do |stop|
    [stop.attributes["offset"], stop.attributes["stop-color"]]
  end
  raise "canonical app icon gradient drifted" unless stops == [["0", "#0E63C4"], ["1", "#0A3D73"]]

  paths = REXML::XPath.match(document, "//*[local-name()='path']")
  expected_paths = [
    ["M 165 614 A 347 347 0 0 1 859 614", "#FFFFFF", "0.5", "26"],
    ["M 312 614 A 200 200 0 0 1 712 614", "#FFFFFF", "0.9", "26"],
  ]
  actual_paths = paths.map do |path|
    %w[d stroke stroke-opacity stroke-width].map { |attribute| path.attributes[attribute] }
  end
  raise "canonical app icon signal geometry drifted" unless actual_paths == expected_paths

  circle = REXML::XPath.first(document, "//*[local-name()='circle']")
  expected_circle = { "cx" => "512", "cy" => "614", "r" => "48", "fill" => "#FFFFFF" }
  actual_circle = expected_circle.keys.to_h { |attribute| [attribute, circle&.attributes&.[](attribute)] }
  raise "canonical app icon center mark drifted" unless actual_circle == expected_circle

  # The outer arc endpoints are the farthest reviewed foreground pixels from
  # the 512px circular-mask center. Include half the stroke width so the check
  # accounts for antialiased ink, not only the path centerline.
  radial_extent = Math.hypot(859.0 - 512.0, 614.0 - 512.0) + (26.0 / 2.0)
  unless radial_extent <= WATCH_ICON_MAX_FOREGROUND_RADIUS
    raise "Watch app icon foreground exceeds the reviewed circular safe radius"
  end

  icon_composer_packages = root.glob("ios/**/*").select do |path|
    path.basename.to_s.end_with?(".icon")
  end
  unless icon_composer_packages.empty?
    raise "an unreviewed Icon Composer package would supersede the Watch app icon catalog"
  end

  true
rescue JSON::ParserError, REXML::ParseException, Errno::ENOENT => error
  raise "invalid Watch app icon contract: #{error.message}"
end

def validate_macos_release_approval!(mac_provenance, expected_source_commit: nil)
  raise "macOS screenshot provenance is not release-approved" unless mac_provenance.fetch("status") == "approved"

  mac_baseline = mac_provenance.fetch("capture").fetch("sourceBaselineCommit")
  unless mac_baseline.is_a?(String) && mac_baseline.match?(/\A[0-9a-f]{40}\z/)
    raise "macOS release-approved provenance needs a full frozen source commit"
  end
  if expected_source_commit
    unless expected_source_commit.match?(/\A[0-9a-f]{40}\z/)
      raise "expected macOS release source commit must be a full lowercase Git SHA"
    end
    raise "macOS frozen screenshot source does not match the release commit" unless mac_baseline == expected_source_commit
  end

  approval = mac_provenance.fetch("releaseApproval")
  raise "macOS signed-build comparison must be approved" unless approval.fetch("signedBuildComparison") == "approved"
  raise "macOS release approval source commit mismatch" unless approval.fetch("sourceBaselineCommit") == mac_baseline
  artifact_digest = approval.fetch("signedArtifactSha256")
  unless artifact_digest.is_a?(String) && artifact_digest.match?(/\A[0-9a-f]{64}\z/)
    raise "macOS release approval needs the signed app or package SHA-256"
  end
  reviewer = approval.fetch("reviewer")
  raise "macOS release approval needs a named reviewer" unless reviewer.is_a?(String) && !reviewer.strip.empty?
  %w[signedBuildComparedAtUtc reviewedAtUtc].each do |field|
    value = approval.fetch(field)
    parsed = Time.iso8601(value)
    raise "macOS release approval #{field} must be UTC" unless value.end_with?("Z") && parsed.utc?
  end
  unless mac_provenance.fetch("currentSet").fetch("status") == "signed-build-approved"
    raise "macOS current screenshot set must record signed-build-approved status"
  end

  true
end

if $PROGRAM_NAME == __FILE__
require_macos_release_ready = false
require_build17_screenshot_release_ready = false
expected_source_commit = nil
screenshot_release_evidence_root = nil
ARGV.each do |argument|
  case argument
  when "--require-macos-release-ready"
    require_macos_release_ready = true
  when "--require-build17-screenshot-release-ready"
    require_build17_screenshot_release_ready = true
  when /\A--expected-source-commit=([0-9a-f]{40})\z/
    expected_source_commit = Regexp.last_match(1)
  when /\A--screenshot-release-evidence-root=(.+)\z/
    if screenshot_release_evidence_root
      warn "--screenshot-release-evidence-root may be supplied only once"
      exit 2
    end
    screenshot_release_evidence_root = Regexp.last_match(1)
  else
    warn "Usage: #{$PROGRAM_NAME} [--require-macos-release-ready] " \
         "[--require-build17-screenshot-release-ready] " \
         "[--expected-source-commit=<40-character-sha>] " \
         "[--screenshot-release-evidence-root=<absolute-existing-directory>]"
    warn "Unknown argument: #{argument}"
    exit 2
  end
end

root = Pathname.new(__dir__).join("..", "..").realpath
ios_store = root.join("ios", "AppStore")
mac_store = root.join("desktop", "AppStore")
validator = StoreAssetValidator.new
expected_mac_screenshots = %w[
  01-home-all-clear.png
  02-event-history.png
  03-monitoring-preferences.png
  04-notification-preferences.png
].to_set
total_ios_screenshots = 0

begin
  AppleScreenshotReleaseSetValidator.new(
    root: root,
    release_evidence_root: screenshot_release_evidence_root,
  ).validate!(
    require_release_ready: require_build17_screenshot_release_ready,
    expected_source_commit:
      require_build17_screenshot_release_ready ? expected_source_commit : nil,
  )
  validate_watch_app_icon_contract!(root)

  # The 1.0 kit remains in the repository as historical release evidence. The
  # current release validator must never silently fall back to that directory.
  manifest_path = ios_store.join("screenshot-manifest-v1.1.json")
  provenance_path = ios_store.join("screenshot-provenance-v1.1.json")
  manifest = JSON.parse(manifest_path.read)
  raise "platform must be iOS/iPadOS" unless manifest.fetch("platform") == "iOS/iPadOS"
  raise "configuration must be Release" unless manifest.fetch("configuration") == "Release"

  provenance = JSON.parse(provenance_path.read)
  allowed_provenance_statuses = %w[release-simulator-validated approved]
  unless allowed_provenance_statuses.include?(provenance.fetch("status"))
    raise "iOS screenshot provenance must have an allowed status"
  end
  product = provenance.fetch("product")
  raise "iOS screenshot provenance configuration mismatch" unless product.fetch("configuration") == "Release"
  raise "iOS screenshot provenance marketing version mismatch" unless product.fetch("marketingVersion") == manifest.fetch("marketingVersion")
  raise "iOS screenshot provenance build mismatch" unless Integer(product.fetch("build")) == Integer(manifest.fetch("build"))
  baseline = provenance.fetch("capture").fetch("sourceBaselineCommit")
  raise "iOS screenshot provenance needs a full source commit" unless baseline.match?(/\A[0-9a-f]{40}\z/)

  mac_provenance = JSON.parse(mac_store.join("screenshot-provenance.json").read)
  allowed_mac_provenance_statuses = %w[pending-signed-mac-app-store-build approved]
  unless allowed_mac_provenance_statuses.include?(mac_provenance.fetch("status"))
    raise "macOS screenshot provenance must have an allowed status"
  end
  unless mac_provenance.fetch("requiredBeforeUpload").fetch("configuration") == "macos-app-store"
    raise "macOS screenshot provenance must require the Mac App Store configuration"
  end
  mac_product = mac_provenance.fetch("product")
  mac_required = mac_provenance.fetch("requiredBeforeUpload")
  desktop_version = JSON.parse(root.join("desktop", "src-tauri", "tauri.conf.json").read).fetch("version")
  raise "macOS screenshot provenance version mismatch" unless mac_product.fetch("version") == desktop_version
  raise "macOS required-before-upload version mismatch" unless mac_required.fetch("version") == desktop_version
  raise "macOS screenshot bundle identifier mismatch" unless mac_product.fetch("bundleIdentifier") == "com.quakesignal.desktop"

  # Ordinary listing CI may mechanically validate a deliberately pending image
  # set. A protected Mac App Store build/upload must additionally prove that
  # the images were bound to frozen source and compared with a signed build.
  # An `approved` record is always held to the stronger schema so the status
  # cannot become a meaningless escape hatch.
  if require_macos_release_ready || mac_provenance.fetch("status") == "approved"
    validate_macos_release_approval!(
      mac_provenance,
      expected_source_commit: require_macos_release_ready ? expected_source_commit : nil,
    )
    if require_macos_release_ready && expected_source_commit.nil?
      raise "macOS release-ready validation requires --expected-source-commit"
    end
  end

  locales = manifest.fetch("locales").map { |locale| locale.fetch("directory") }
  frames = manifest.fetch("frames").map { |frame| frame.fetch("file") }
  display_classes = manifest.fetch("displayClasses")
  raise "at least one upload display class is required" unless display_classes.any? { |_name, detail| detail.fetch("upload") }

  duplicate_locales = locales.group_by(&:itself).select { |_name, values| values.length > 1 }.keys
  duplicate_frames = frames.group_by(&:itself).select { |_name, values| values.length > 1 }.keys
  validator.error("duplicate iOS screenshot locales: #{duplicate_locales.join(', ')}") unless duplicate_locales.empty?
  validator.error("duplicate iOS screenshot frames: #{duplicate_frames.join(', ')}") unless duplicate_frames.empty?

  locales.each do |locale|
    validator.validate_ios_listing_copy(ios_store.join(locale))
  end

  platform_store = ios_store.join("platforms")
  %w[tvos visionos maccatalyst].each do |platform|
    validator.validate_platform_listing_copy(platform_store.join(platform, "en-US"))
    validator.validate_submission_document(
      platform_store.join(platform, "review-notes.txt"),
      "#{platform} App Review notes",
      ["QuakeSignal", "jma_eew", "jma_eqlist", "JMA"],
    )
  end
  watch_description_path = platform_store.join("watchos", "en-US", "description.txt")
  watch_description = validator.listing_text(watch_description_path)
  validator.validate_character_limit(
    watch_description_path,
    watch_description,
    StoreAssetValidator::MAX_DESCRIPTION_CHARACTERS,
    "description",
  )
  validator.validate_submission_document(
    platform_store.join("watchos", "review-notes.txt"),
    "watchOS App Review notes",
    ["QuakeSignal", "jma_eew", "jma_eqlist", "JMA"],
  )

  screenshot_root_name = manifest.fetch("rootDirectory")
  unless Pathname.new(screenshot_root_name).basename.to_s == screenshot_root_name
    raise "iOS screenshot rootDirectory must be a directory name"
  end
  ios_screenshots = ios_store.join(screenshot_root_name)
  unless ios_screenshots.directory?
    validator.error("missing iOS screenshot directory: #{ios_screenshots}")
  end

  expected_locale_dirs = locales.to_set
  actual_locale_dirs = ios_screenshots.directory? ? ios_screenshots.children.select(&:directory?) : []
  actual_locale_dirs.each do |directory|
    unless expected_locale_dirs.include?(directory.basename.to_s)
      validator.error("unexpected iOS screenshot locale directory: #{directory}")
    end
  end

  locales.each do |locale|
    locale_directory = ios_screenshots.join(locale)
    actual_class_dirs = locale_directory.directory? ? locale_directory.children.select(&:directory?) : []
    expected_class_dirs = display_classes.keys.to_set
    actual_class_dirs.each do |directory|
      unless expected_class_dirs.include?(directory.basename.to_s)
        validator.error("unexpected iOS screenshot class directory: #{directory}")
      end
    end

    display_classes.each do |display_class, specification|
      class_directory = locale_directory.join(display_class)
      required = specification.fetch("upload")
      expected_files = frames.to_set
      actual_files = class_directory.directory? ? class_directory.children.select(&:file?) : []
      actual_names = actual_files.map { |file| file.basename.to_s }.to_set

      unless class_directory.directory?
        validator.error("missing required iOS screenshot directory: #{class_directory}") if required
        next
      end

      unexpected = actual_names - expected_files
      missing = expected_files - actual_names
      unless unexpected.empty?
        validator.error("#{class_directory}: unexpected screenshots: #{unexpected.to_a.sort.join(', ')}")
      end
      unless missing.empty?
        validator.error("#{class_directory}: missing screenshots: #{missing.to_a.sort.join(', ')}") if required || !actual_names.empty?
      end

      dimensions = [[
        Integer(specification.fetch("portraitPixels").fetch(0)),
        Integer(specification.fetch("portraitPixels").fetch(1)),
      ]]
      actual_files.each do |file|
        next unless expected_files.include?(file.basename.to_s)

        validator.validate_image(file, formats: %w[jpeg png], dimensions: dimensions)
        total_ios_screenshots += 1
      end
    end
  end

  provenance_files = provenance.fetch("files")
  provenance_by_path = {}
  provenance_files.each do |entry|
    relative_path = entry.fetch("file")
    if provenance_by_path.key?(relative_path)
      validator.error("#{provenance_path}: duplicate file entry: #{relative_path}")
    else
      provenance_by_path[relative_path] = entry
    end
  end

  expected_relative_paths = locales.flat_map do |locale|
    display_classes.select { |_name, specification| specification.fetch("upload") }.keys.flat_map do |display_class|
      frames.map { |frame| File.join(locale, display_class, frame) }
    end
  end.to_set
  recorded_relative_paths = provenance_by_path.keys.to_set
  missing_provenance = expected_relative_paths - recorded_relative_paths
  unexpected_provenance = recorded_relative_paths - expected_relative_paths
  validator.error("#{provenance_path}: missing file records: #{missing_provenance.to_a.sort.join(', ')}") unless missing_provenance.empty?
  validator.error("#{provenance_path}: unexpected file records: #{unexpected_provenance.to_a.sort.join(', ')}") unless unexpected_provenance.empty?

  expected_relative_paths.each do |relative_path|
    entry = provenance_by_path[relative_path]
    next unless entry

    screenshot = ios_screenshots.join(relative_path)
    next unless screenshot.file?

    actual_digest = Digest::SHA256.file(screenshot).hexdigest
    validator.error("#{screenshot}: SHA-256 does not match provenance") unless entry.fetch("sha256") == actual_digest
    validator.error("#{provenance_path}: #{relative_path} must be recorded as opaque") unless entry.fetch("hasAlpha") == false

    display_class = relative_path.split(File::SEPARATOR).fetch(1)
    expected_pixels = display_classes.fetch(display_class).fetch("portraitPixels").map { |value| Integer(value) }
    recorded_pixels = entry.fetch("pixels").map { |value| Integer(value) }
    validator.error("#{provenance_path}: #{relative_path} pixel record mismatch") unless recorded_pixels == expected_pixels
    validator.error("#{provenance_path}: #{relative_path} format must be jpeg") unless entry.fetch("format").downcase == "jpeg"
  end

  validator.validate_macos_listing_copy(mac_store.join("en-US"))
  validator.validate_submission_document(
    ios_store.join("review-notes.txt"),
    "iOS App Review notes",
    ["QuakeSignal", "Wolfx", "No account"],
  )
  validator.validate_submission_document(
    ios_store.join("submission-answers.md"),
    "iOS App Store Connect submission answers",
    ["Content Rights", "Wolfx"],
  )
  validator.validate_submission_checklist(
    ios_store.join("submission-checklist.md"),
    "iOS App Store Connect pre-submission checklist",
  )
  validator.validate_submission_document(
    mac_store.join("review-notes.txt"),
    "macOS App Review notes",
    ["QuakeSignal", "Wolfx", "does not require an account"],
  )
  validator.validate_submission_document(
    mac_store.join("submission-answers.md"),
    "macOS App Store Connect submission answers",
    ["Content Rights", "Wolfx"],
  )
  validator.validate_submission_checklist(
    mac_store.join("submission-checklist.md"),
    "macOS App Store Connect pre-submission checklist",
  )

  mac_screenshot_directory = mac_store.join("screenshots", "en-US")
  actual_mac_screenshots = mac_screenshot_directory.directory? ? mac_screenshot_directory.children.select(&:file?) : []
  actual_mac_names = actual_mac_screenshots.map { |file| file.basename.to_s }.to_set
  missing_mac = expected_mac_screenshots - actual_mac_names
  unexpected_mac = actual_mac_names - expected_mac_screenshots
  unless missing_mac.empty?
    validator.error("#{mac_screenshot_directory}: missing screenshots: #{missing_mac.to_a.sort.join(', ')}")
  end
  unless unexpected_mac.empty?
    validator.error("#{mac_screenshot_directory}: unexpected screenshots: #{unexpected_mac.to_a.sort.join(', ')}")
  end

  actual_mac_screenshots.each do |file|
    next unless expected_mac_screenshots.include?(file.basename.to_s)

    validator.validate_image(file, formats: ["png"], dimensions: [[1280, 800]])
  end

  mac_provenance_files = mac_provenance.fetch("files")
  mac_provenance_by_path = {}
  mac_provenance_files.each do |entry|
    relative_path = entry.fetch("file")
    if mac_provenance_by_path.key?(relative_path)
      validator.error("#{mac_store.join('screenshot-provenance.json')}: duplicate file entry: #{relative_path}")
    else
      mac_provenance_by_path[relative_path] = entry
    end
  end
  expected_mac_relative_paths = expected_mac_screenshots.map { |name| File.join("screenshots", "en-US", name) }.to_set
  missing_mac_provenance = expected_mac_relative_paths - mac_provenance_by_path.keys.to_set
  unexpected_mac_provenance = mac_provenance_by_path.keys.to_set - expected_mac_relative_paths
  validator.error("macOS provenance missing file records: #{missing_mac_provenance.to_a.sort.join(', ')}") unless missing_mac_provenance.empty?
  validator.error("macOS provenance has unexpected file records: #{unexpected_mac_provenance.to_a.sort.join(', ')}") unless unexpected_mac_provenance.empty?

  expected_mac_relative_paths.each do |relative_path|
    entry = mac_provenance_by_path[relative_path]
    next unless entry

    screenshot = mac_store.join(relative_path)
    next unless screenshot.file?

    validator.error("#{screenshot}: SHA-256 does not match provenance") unless entry.fetch("sha256") == Digest::SHA256.file(screenshot).hexdigest
    validator.error("#{screenshot}: provenance pixels must be 1280x800") unless entry.fetch("pixels").map { |value| Integer(value) } == [1280, 800]
    validator.error("#{screenshot}: provenance format must be png") unless entry.fetch("format").downcase == "png"
    validator.error("#{screenshot}: provenance must record an opaque image") unless entry.fetch("hasAlpha") == false
  end
rescue AppleScreenshotReleaseSetValidationError, JSON::ParserError, KeyError, TypeError,
       ArgumentError, RuntimeError, SystemCallError => error
  validator.error("invalid store asset manifest or provenance: #{error.message}")
end

validator.finish!
puts "Store listing assets validated: #{total_ios_screenshots} iOS screenshots and #{expected_mac_screenshots.length} macOS screenshots."
end
