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
  (REVIEWED_FRAMES - ["visionos-map", "visionos-guide"]).each do |frame|
    stdout, stderr, status = run_validator(valid_app_panel_path, frame: frame)
    assert(status.success?, "structured app-panel fixture should pass #{frame}: #{stderr}")
    assert(
      stdout.include?("Validated Vision frame semantic pixels for #{frame}"),
      "validator should report accepted metrics for #{frame}",
    )
  end

  # Model the reviewed opaque Guide window: a broad, slowly changing neutral
  # surface supplies readable contrast and color-bin diversity while four
  # sparse text-detail samples keep the edge fraction below the generic 1%
  # route floor. This exercises the Guide-only structural contract instead of
  # weakening readiness for every Vision route.
  reviewed_guide_path = File.join(directory, "reviewed-guide.bmp")
  reviewed_guide_details = {
    [140, 87] => 15,
    [180, 111] => 240,
    [220, 135] => 15,
    [260, 159] => 240,
  }.freeze
  channel_offsets = [-12, 0, 12].freeze
  build_bitmap(reviewed_guide_path) do |x, y|
    detail_shade = reviewed_guide_details[[x, y]]
    if detail_shade
      [detail_shade, detail_shade, detail_shade]
    else
      shade = 75 + ((x + y - 187) * 127 / 260)
      shade = [[shade, 75].max, 202].min
      red = shade + channel_offsets[(x / 16) % channel_offsets.length]
      green = shade + channel_offsets[(y / 16) % channel_offsets.length]
      blue = shade + channel_offsets[((x + y) / 16) % channel_offsets.length]
      [red, green, blue]
    end
  end
  stdout, stderr, status = run_validator(
    reviewed_guide_path,
    frame: "visionos-guide",
  )
  assert(status.success?, "reviewed low-edge Guide structure should pass: #{stderr}")
  assert(
    stdout.include?("Validated Vision frame semantic pixels for visionos-guide"),
    "validator should report accepted Guide metrics",
  )

  low_edge_guide_path = File.join(directory, "low-edge-guide.bmp")
  low_edge_guide_details = {
    [180, 111] => 240,
    [220, 135] => 15,
  }.freeze
  build_bitmap(low_edge_guide_path) do |x, y|
    detail_shade = low_edge_guide_details[[x, y]]
    if detail_shade
      [detail_shade, detail_shade, detail_shade]
    else
      shade = 75 + ((x + y - 187) * 127 / 260)
      shade = [[shade, 75].max, 202].min
      red = shade + channel_offsets[(x / 16) % channel_offsets.length]
      green = shade + channel_offsets[(y / 16) % channel_offsets.length]
      blue = shade + channel_offsets[((x + y) / 16) % channel_offsets.length]
      [red, green, blue]
    end
  end
  _stdout, stderr, status = run_validator(
    low_edge_guide_path,
    frame: "visionos-guide",
  )
  assert(!status.success?, "Guide-like gradient without enough text edges must fail")
  assert(status.exitstatus == 65, "low-edge Guide rejection must use status 65")

  high_edge_guide_path = File.join(directory, "high-edge-guide.bmp")
  high_edge_guide_details = reviewed_guide_details.merge(
    [132, 79] => 15,
    [156, 99] => 240,
    [204, 123] => 15,
    [244, 147] => 240,
  ).freeze
  build_bitmap(high_edge_guide_path) do |x, y|
    detail_shade = high_edge_guide_details[[x, y]]
    if detail_shade
      [detail_shade, detail_shade, detail_shade]
    else
      shade = 75 + ((x + y - 187) * 127 / 260)
      shade = [[shade, 75].max, 202].min
      red = shade + channel_offsets[(x / 16) % channel_offsets.length]
      green = shade + channel_offsets[(y / 16) % channel_offsets.length]
      blue = shade + channel_offsets[((x + y) / 16) % channel_offsets.length]
      [red, green, blue]
    end
  end
  _stdout, stderr, status = run_validator(
    high_edge_guide_path,
    frame: "visionos-guide",
  )
  assert(!status.success?, "unreviewed high-edge layout must fail the Guide envelope")
  assert(status.exitstatus == 65, "high-edge Guide rejection must use status 65")

  _stdout, stderr, status = run_validator(
    reviewed_guide_path,
    frame: "visionos-home",
  )
  assert(!status.success?, "Guide exception must not weaken the generic Home edge floor")
  assert(status.exitstatus == 65, "Guide-as-Home rejection must use status 65")
  assert(stderr.include?("refusing blank launch placeholder"), "Guide-as-Home rejection should be explicit")

  _stdout, stderr, status = run_validator(
    valid_app_panel_path,
    frame: "visionos-guide",
  )
  assert(!status.success?, "generic high-edge app panel must not impersonate the reviewed Guide")
  assert(status.exitstatus == 65, "wrong-route Guide rejection must use status 65")
  assert(stderr.include?("Vision Guide lacks reviewed list-and-text pixel structure"), "Guide rejection should identify its route contract")

  # A bright system sheet with dark text bars has substantial variance and
  # edges, but its low color-bin inventory is not the reviewed Guide surface.
  system_dialog_path = File.join(directory, "system-dialog.bmp")
  build_bitmap(system_dialog_path) do |x, y|
    if x.between?(90, 310) && y.between?(45, 195)
      if y.between?(88, 95) || y.between?(112, 119) || y.between?(150, 157)
        [35, 35, 35]
      else
        [240, 240, 240]
      end
    else
      [145, 145, 145]
    end
  end
  _stdout, stderr, status = run_validator(
    system_dialog_path,
    frame: "visionos-guide",
  )
  assert(!status.success?, "system dialog structure must not impersonate the reviewed Guide")
  assert(status.exitstatus == 65, "system-dialog Guide rejection must use status 65")
  assert(stderr.include?("Vision Guide lacks reviewed list-and-text pixel structure"), "system-dialog rejection should identify the Guide contract")

  _stdout, stderr, status = run_validator(
    valid_map_path,
    frame: "visionos-guide",
  )
  assert(!status.success?, "chromatic Map pixels must not impersonate the reviewed Guide")
  assert(status.exitstatus == 65, "Map-as-Guide rejection must use status 65")
  assert(stderr.include?("Vision Guide lacks reviewed list-and-text pixel structure"), "Map-as-Guide rejection should identify the Guide contract")

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
