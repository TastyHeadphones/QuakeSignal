#!/usr/bin/ruby

require "open3"
require "rbconfig"
require "tmpdir"

VALIDATOR = File.expand_path("validate-vision-map-content.rb", __dir__)
WIDTH = 400
HEIGHT = 240
REVIEWED_FRAMES = %w[
  visionos-home
  visionos-reports
  visionos-map
  visionos-guide
  visionos-alert-preferences
].freeze

def build_bitmap(path)
  row_stride = ((WIDTH * 3 + 3) / 4) * 4
  pixel_bytes = String.new(capacity: row_stride * HEIGHT, encoding: Encoding::BINARY)
  HEIGHT.times do |y|
    WIDTH.times do |x|
      red, green, blue = yield(x, y)
      pixel_bytes << [blue, green, red].pack("C3")
    end
    pixel_bytes << "\0" * (row_stride - WIDTH * 3)
  end

  pixel_offset = 54
  file_header = "BM" + [pixel_offset + pixel_bytes.bytesize, 0, 0, pixel_offset].pack("VvvV")
  dib_header = [40].pack("V") +
    [WIDTH, -HEIGHT].pack("l<l<") +
    [1, 24].pack("vv") +
    [0, pixel_bytes.bytesize, 2_835, 2_835, 0, 0].pack("VVl<l<VV")
  File.binwrite(path, file_header + dib_header + pixel_bytes)
end

def run_validator(path, width: WIDTH, height: HEIGHT, frame: "visionos-map")
  Open3.capture3(RbConfig.ruby, VALIDATOR, path, width.to_s, height.to_s, frame)
end

def assert(condition, message)
  abort "error: #{message}" unless condition
end

Dir.mktmpdir("quakesignal-vision-validator-test.") do |directory|
  valid_map_path = File.join(directory, "valid-map.bmp")
  build_bitmap(valid_map_path) do |x, y|
    if ((x / 8) + (y / 8)) % 17 == 0
      [245, 245, 245]
    else
      red = (x * 3 + y * 5) % 58
      green = 75 + (x * 7 + y * 3) % 150
      blue = 125 + (x * 5 + y * 11) % 125
      [red, green, blue]
    end
  end
  stdout, stderr, status = run_validator(valid_map_path)
  assert(status.success?, "diverse blue map fixture should pass: #{stderr}")
  assert(
    stdout.include?("Validated Vision frame semantic pixels for visionos-map"),
    "validator should report accepted map metrics",
  )

  valid_app_panel_path = File.join(directory, "valid-app-panel.bmp")
  build_bitmap(valid_app_panel_path) do |x, y|
    shade = ((x / 8) + (y / 8)).even? ? 24 : 232
    [shade, shade, shade]
  end
  (REVIEWED_FRAMES - ["visionos-map"]).each do |frame|
    stdout, stderr, status = run_validator(valid_app_panel_path, frame: frame)
    assert(status.success?, "structured app-panel fixture should pass #{frame}: #{stderr}")
    assert(
      stdout.include?("Validated Vision frame semantic pixels for #{frame}"),
      "validator should report accepted metrics for #{frame}",
    )
  end

  smooth_high_variance_path = File.join(directory, "smooth-high-variance.bmp")
  build_bitmap(smooth_high_variance_path) do |x, _y|
    shade = (x * 255) / (WIDTH - 1)
    [shade, shade, shade]
  end
  _stdout, stderr, status = run_validator(
    smooth_high_variance_path,
    frame: "visionos-home",
  )
  assert(!status.success?, "high luma variance without meaningful edges must fail readiness")
  assert(status.exitstatus == 65, "low-edge semantic rejection must use status 65")
  assert(stderr.include?("edges 0.000%"), "low-edge rejection should expose edge evidence")

  edged_low_variance_path = File.join(directory, "edged-low-variance.bmp")
  build_bitmap(edged_low_variance_path) do |x, y|
    shade = ((x / 8) + (y / 8)).even? ? 112 : 138
    [shade, shade, shade]
  end
  _stdout, stderr, status = run_validator(
    edged_low_variance_path,
    frame: "visionos-home",
  )
  assert(!status.success?, "meaningful edges without sufficient luma variance must fail readiness")
  assert(status.exitstatus == 65, "low-variance semantic rejection must use status 65")
  assert(stderr.include?("luma sd 13.00"), "low-variance rejection should expose luma evidence")

  logo_placeholder_path = File.join(directory, "logo-placeholder.bmp")
  build_bitmap(logo_placeholder_path) do |x, y|
    distance_squared = (x - WIDTH / 2)**2 + (y - HEIGHT / 2)**2
    distance_squared <= 12**2 ? [35, 115, 225] : [150, 150, 150]
  end
  _stdout, stderr, status = run_validator(
    logo_placeholder_path,
    frame: "visionos-home",
  )
  assert(!status.success?, "flat launch panel with a small blue logo must fail Home readiness")
  assert(status.exitstatus == 65, "logo-placeholder semantic rejection must use status 65")
  assert(
    stderr.include?("refusing blank launch placeholder"),
    "logo-placeholder rejection should be explicit",
  )

  blank_path = File.join(directory, "blank.bmp")
  build_bitmap(blank_path) do |x, y|
    shade = 145 + ((x + y) % 18)
    [shade, shade, shade]
  end
  REVIEWED_FRAMES.each do |frame|
    _stdout, stderr, status = run_validator(blank_path, frame: frame)
    assert(!status.success?, "low-diversity gray launch placeholder must fail #{frame}")
    assert(status.exitstatus == 65, "semantic blank rejection must use status 65 for #{frame}")
    assert(
      stderr.include?("refusing blank launch placeholder"),
      "blank failure should be explicit for #{frame}",
    )
  end

  _stdout, stderr, status = run_validator(valid_app_panel_path)
  assert(!status.success?, "high-variance grayscale must not impersonate a map")
  assert(status.exitstatus == 65, "semantic grayscale rejection must use status 65")
  assert(stderr.include?("map-blue 0.00%"), "grayscale rejection should expose missing map-blue pixels")

  warm_path = File.join(directory, "warm.bmp")
  build_bitmap(warm_path) do |x, y|
    red = 130 + (x * 5 + y * 3) % 125
    green = (x * 7 + y * 11) % 100
    blue = (x + y) % 25
    [red, green, blue]
  end
  _stdout, stderr, status = run_validator(warm_path)
  assert(!status.success?, "diverse saturated warm pixels must not impersonate map ocean")
  assert(status.exitstatus == 65, "semantic warm-color rejection must use status 65")
  assert(stderr.include?("map-blue 0.00%"), "warm rejection should expose missing map-blue pixels")

  flat_blue_path = File.join(directory, "flat-blue.bmp")
  build_bitmap(flat_blue_path) do |x, y|
    ((x + y) % 101).zero? ? [255, 255, 255] : [20, 110, 180]
  end
  _stdout, stderr, status = run_validator(flat_blue_path)
  assert(!status.success?, "nearly flat blue placeholder must fail the diversity contract")
  assert(status.exitstatus == 65, "semantic flat-blue rejection must use status 65")
  assert(stderr.include?("q16 bins"), "flat-blue rejection should expose color-bin evidence")

  _stdout, stderr, status = run_validator(valid_map_path, width: WIDTH + 1)
  assert(!status.success?, "dimension mismatch must fail")
  assert(status.exitstatus == 70, "bitmap dimension mismatch must be operational status 70")
  assert(stderr.include?("unsupported Vision validation bitmap layout"), "dimension failure should identify layout")

  truncated_path = File.join(directory, "truncated.bmp")
  File.binwrite(truncated_path, File.binread(valid_map_path).byteslice(0, 60))
  _stdout, stderr, status = run_validator(truncated_path)
  assert(!status.success?, "truncated bitmap must fail")
  assert(status.exitstatus == 70, "truncated bitmap must be operational status 70")
  assert(stderr.include?("truncated Vision validation bitmap"), "truncation failure should be explicit")

  _stdout, stderr, status = run_validator(valid_map_path, frame: "visionos-emergency-history")
  assert(!status.success?, "validator must reject unreviewed frame selectors")
  assert(status.exitstatus == 64, "unreviewed selector must be usage status 64")
  assert(stderr.include?("unreviewed Vision frame selector"), "selector failure should be explicit")

  _stdout, stderr, status = run_validator(File.join(directory, "missing.bmp"))
  assert(!status.success?, "missing bitmap must fail")
  assert(status.exitstatus == 70, "missing bitmap must be operational status 70")
  assert(stderr.include?("could not read Vision validation bitmap"), "missing bitmap failure should be explicit")
end

puts "Vision semantic validator tests passed"
