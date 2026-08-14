#!/usr/bin/env ruby
# frozen_string_literal: true

# Deterministic structural validation for the local App Store listing kits.
# This intentionally checks only committed metadata and image properties; it
# does not render the app, contact App Store Connect, or modify any asset.

require "json"
require "open3"
require "pathname"
require "set"

class StoreAssetValidator
  MAX_DESCRIPTION_CHARACTERS = 4000
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
  # the reviewer route or the Wolfx content-rights gate.
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
  # that Content Rights/Wolfx remains a real checkbox item without requiring
  # either an unfinished marker or a particular completion state.
  def validate_submission_checklist(path, document_name)
    validate_submission_document(path, document_name, ["Content Rights", "Wolfx"])
    return unless path.file? && path.size.positive?

    text = path.read(encoding: "UTF-8")
    return if text.match?(/^- \[[ xX]\] \*\*Content Rights\b.*?\bWolfx\b/m)

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

  def validate_ios_listing_copy(directory)
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
  manifest = JSON.parse(ios_store.join("screenshot-manifest.json").read)
  raise "platform must be iOS" unless manifest.fetch("platform") == "iOS"

  provenance = JSON.parse(ios_store.join("screenshot-provenance.json").read)
  allowed_provenance_statuses = %w[pending-public-release-candidate approved]
  unless allowed_provenance_statuses.include?(provenance.fetch("status"))
    raise "iOS screenshot provenance must have an allowed status"
  end
  unless provenance.fetch("requiredBeforeUpload").fetch("configuration") == "Release"
    raise "iOS screenshot provenance must require Release configuration"
  end
  unless Integer(provenance.fetch("requiredBeforeUpload").fetch("minimumCFBundleVersion")) >= 3
    raise "iOS screenshot provenance must require a public build number of at least 3"
  end

  mac_provenance = JSON.parse(mac_store.join("screenshot-provenance.json").read)
  allowed_mac_provenance_statuses = %w[pending-signed-mac-app-store-build approved]
  unless allowed_mac_provenance_statuses.include?(mac_provenance.fetch("status"))
    raise "macOS screenshot provenance must have an allowed status"
  end
  unless mac_provenance.fetch("requiredBeforeUpload").fetch("configuration") == "macos-app-store"
    raise "macOS screenshot provenance must require the Mac App Store configuration"
  end

  locales = manifest.fetch("locales").map { |locale| locale.fetch("directory") }
  frames = manifest.fetch("frames").map { |frame| frame.fetch("file") }
  display_classes = manifest.fetch("displayClasses")
  primary_display_class = manifest.fetch("primaryDisplayClass")
  raise "at least one upload display class is required" unless display_classes.any? { |_name, detail| detail.fetch("upload") }
  raise "primary display class must upload" unless display_classes.fetch(primary_display_class).fetch("upload")

  duplicate_locales = locales.group_by(&:itself).select { |_name, values| values.length > 1 }.keys
  duplicate_frames = frames.group_by(&:itself).select { |_name, values| values.length > 1 }.keys
  validator.error("duplicate iOS screenshot locales: #{duplicate_locales.join(', ')}") unless duplicate_locales.empty?
  validator.error("duplicate iOS screenshot frames: #{duplicate_frames.join(', ')}") unless duplicate_frames.empty?

  locales.each do |locale|
    validator.validate_ios_listing_copy(ios_store.join(locale))
  end

  ios_screenshots = ios_store.join("screenshots")
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
    expected_class_dirs = display_classes.keys.map { |name| "iphone-#{name}" }.to_set
    actual_class_dirs.each do |directory|
      unless expected_class_dirs.include?(directory.basename.to_s)
        validator.error("unexpected iOS screenshot class directory: #{directory}")
      end
    end

    display_classes.each do |display_class, specification|
      class_directory = locale_directory.join("iphone-#{display_class}")
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

      dimensions = specification.fetch("acceptedPortraitPixels").map do |pair|
        [Integer(pair.fetch(0)), Integer(pair.fetch(1))]
      end
      actual_files.each do |file|
        next unless expected_files.include?(file.basename.to_s)

        validator.validate_image(file, formats: %w[jpeg png], dimensions: dimensions)
        total_ios_screenshots += 1
      end
    end
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
rescue JSON::ParserError, KeyError, TypeError, ArgumentError, SystemCallError => error
  validator.error("invalid iOS screenshot manifest: #{error.message}")
end

validator.finish!
puts "Store listing assets validated: #{total_ios_screenshots} iOS screenshots and #{expected_mac_screenshots.length} macOS screenshots."
