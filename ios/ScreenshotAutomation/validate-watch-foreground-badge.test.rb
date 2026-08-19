#!/usr/bin/ruby

require "open3"
require "rbconfig"
require "tmpdir"

VALIDATOR = File.expand_path("validate-watch-foreground-badge.rb", __dir__)
WIDTH = 100
HEIGHT = 100

def build_bitmap(path, pixels)
  row_stride = ((WIDTH * 3 + 3) / 4) * 4
  pixel_bytes = String.new(capacity: row_stride * HEIGHT, encoding: Encoding::BINARY)
  HEIGHT.times do |y|
    WIDTH.times do |x|
      red, green, blue = pixels.fetch([x, y], [0, 0, 0])
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

def run_validator(path, width: WIDTH, height: HEIGHT, frame: "watchos-headline")
  Open3.capture3(RbConfig.ruby, VALIDATOR, path, width.to_s, height.to_s, frame)
end

def assert(condition, message)
  abort "error: #{message}" unless condition
end

Dir.mktmpdir("quakesignal-watch-badge-test.") do |directory|
  good_pixels = {}
  (25...35).each do |y|
    (5...15).each { |x| good_pixels[[x, y]] = [255, 149, 0] }
  end
  good_path = File.join(directory, "good.bmp")
  build_bitmap(good_path, good_pixels)
  stdout, stderr, status = run_validator(good_path)
  assert(status.success?, "100 in-region badge pixels should pass: #{stderr}")
  assert(stdout.include?("100 orange pixels"), "validator should report the accepted pixel count")
  _stdout, _stderr, status = run_validator(good_path, frame: "watchos-event-detail")
  assert(!status.success?, "dashboard marker density must not pass the detail route")

  detail_pixels = {}
  (20...30).each do |y|
    (5...20).each { |x| detail_pixels[[x, y]] = [255, 149, 0] }
  end
  detail_path = File.join(directory, "detail.bmp")
  build_bitmap(detail_path, detail_pixels)
  stdout, stderr, status = run_validator(detail_path, frame: "watchos-event-detail")
  assert(status.success?, "detail badge pixels in the route-specific upper band should pass: #{stderr}")
  assert(stdout.include?("150 orange pixels"), "detail validator should report the accepted pixel count")
  _stdout, stderr, status = run_validator(detail_path, frame: "watchos-headline")
  assert(!status.success?, "detail-only upper pixels must not widen the dashboard badge band")
  assert(stderr.include?("found 150, maximum 120"), "detail marker should exceed the dashboard density cap")
  assert(stderr.include?("full-frame qualifying orange pixels: 150"), "density rejection should expose full-frame evidence")

  top_detail_pixels = {}
  (1...11).each do |y|
    (5...20).each { |x| top_detail_pixels[[x, y]] = [255, 149, 0] }
  end
  top_detail_path = File.join(directory, "top-detail.bmp")
  build_bitmap(top_detail_path, top_detail_pixels)
  stdout, stderr, status = run_validator(top_detail_path, frame: "watchos-event-detail")
  assert(status.success?, "detail banner pixels above a safe-area assumption should pass: #{stderr}")
  assert(stdout.include?("150 orange pixels"), "top detail validation should report its pixel count")
  _stdout, stderr, status = run_validator(top_detail_path, frame: "watchos-headline")
  assert(!status.success?, "top detail banner must not be accepted as a dashboard marker")
  assert(stderr.include?("found 0, need 100"), "dashboard rejection should remain band-specific")
  assert(stderr.include?("full-frame qualifying orange pixels: 150"), "failure telemetry should expose out-of-band orange")

  clock_pixels = {}
  (25...35).each do |y|
    (5...15).each { |x| clock_pixels[[x, y]] = [230, 255, 14] }
    (20...30).each { |x| clock_pixels[[x, y]] = [255, 190, 160] }
  end
  clock_path = File.join(directory, "clock.bmp")
  build_bitmap(clock_path, clock_pixels)
  _stdout, stderr, status = run_validator(clock_path)
  assert(!status.success?, "clock-face chartreuse and peach pixels must fail")
  assert(stderr.include?("found 0, need 100"), "clock rejection should report zero qualifying pixels")
  _stdout, stderr, status = run_validator(clock_path, frame: "watchos-event-detail")
  assert(!status.success?, "clock-face colors must also fail the detail route band")
  assert(stderr.include?("found 0, need 150"), "detail clock rejection should report zero qualifying pixels")
  assert(stderr.include?("full-frame qualifying orange pixels: 0"), "clock rejection should report full-frame evidence")

  outside_pixels = {}
  (50...60).each do |y|
    (5...15).each { |x| outside_pixels[[x, y]] = [255, 149, 0] }
  end
  outside_path = File.join(directory, "outside-region.bmp")
  build_bitmap(outside_path, outside_pixels)
  _stdout, _stderr, status = run_validator(outside_path)
  assert(!status.success?, "orange pixels outside the upper content band must fail")
  _stdout, stderr, status = run_validator(outside_path, frame: "watchos-event-detail")
  assert(!status.success?, "orange pixels below the detail upper content band must fail")
  assert(stderr.include?("found 0, need 150"), "detail below-band rejection should report zero reviewed pixels")
  assert(stderr.include?("full-frame qualifying orange pixels: 100"), "detail below-band rejection should report full-frame evidence")

  below_threshold_pixels = good_pixels.dup
  below_threshold_pixels.delete([14, 34])
  below_threshold_path = File.join(directory, "below-threshold.bmp")
  build_bitmap(below_threshold_path, below_threshold_pixels)
  _stdout, stderr, status = run_validator(below_threshold_path)
  assert(!status.success?, "99 qualifying pixels must fail")
  assert(stderr.include?("found 99, need 100"), "threshold rejection should report 99 pixels")

  _stdout, stderr, status = run_validator(good_path, width: WIDTH + 1)
  assert(!status.success?, "dimension mismatch must fail")
  assert(stderr.include?("unsupported Watch validation bitmap layout"), "dimension failure should identify the layout")

  truncated_path = File.join(directory, "truncated.bmp")
  File.binwrite(truncated_path, File.binread(good_path).byteslice(0, 60))
  _stdout, stderr, status = run_validator(truncated_path)
  assert(!status.success?, "truncated bitmap must fail")
  assert(stderr.include?("truncated Watch validation bitmap"), "truncation failure should be explicit")

  _stdout, stderr, status = run_validator(good_path, frame: "watchos-unreviewed")
  assert(!status.success?, "an unreviewed frame selector must fail")
  assert(stderr.include?("unreviewed Watch frame selector"), "selector failure should be explicit")
end

puts "Watch foreground badge validator tests passed"
