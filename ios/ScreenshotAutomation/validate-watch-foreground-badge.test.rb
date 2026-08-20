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

def assert_exit_status(status, expected, label)
  assert(!status.success?, "#{label} must fail")
  assert(
    status.exitstatus == expected,
    "#{label} must use status #{expected}, got #{status.exitstatus.inspect}",
  )
end

_stdout, stderr, status = Open3.capture3(RbConfig.ruby, VALIDATOR)
assert_exit_status(status, 64, "missing validator arguments")
assert(stderr.include?("usage: validate-watch-foreground-badge.rb"), "usage failure should be explicit")

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
  assert_exit_status(status, 65, "dashboard marker density on the detail route")

  recent_pixels = {}
  (25...35).each do |y|
    (56...66).each { |x| recent_pixels[[x, y]] = [255, 149, 0] }
  end
  recent_path = File.join(directory, "recent-complete.bmp")
  build_bitmap(recent_path, recent_pixels)
  stdout, stderr, status = run_validator(recent_path, frame: "watchos-recent-reports")
  assert(status.success?, "a complete recent-reports label reaching the reviewed extent should pass: #{stderr}")
  assert(stdout.include?("100 orange pixels"), "recent validator should report the accepted pixel count")

  _stdout, stderr, status = run_validator(good_path, frame: "watchos-recent-reports")
  assert_exit_status(status, 65, "recent-reports label clipped before the reviewed extent")
  assert(stderr.include?("rightmost orange pixel 14, need at least 60"), "extent rejection should expose its evidence")

  sparse_recent_pixels = recent_pixels.dup
  sparse_recent_pixels.delete([65, 34])
  sparse_recent_path = File.join(directory, "recent-sparse.bmp")
  build_bitmap(sparse_recent_path, sparse_recent_pixels)
  _stdout, stderr, status = run_validator(sparse_recent_path, frame: "watchos-recent-reports")
  assert_exit_status(status, 65, "recent-reports label below the route-specific density")
  assert(stderr.include?("found 99 orange pixels, need 100"), "recent density rejection should expose its evidence")
  assert(stderr.include?("refusing a truncated first viewport"), "recent density rejection should identify clipping")

  allowed_bottom_pixels = good_pixels.dup
  (15...36).each { |x| allowed_bottom_pixels[[x, 94]] = [17, 17, 17] }
  allowed_bottom_path = File.join(directory, "allowed-bottom-noise.bmp")
  build_bitmap(allowed_bottom_path, allowed_bottom_pixels)
  _stdout, stderr, status = run_validator(allowed_bottom_path)
  assert(status.success?, "bottom central-band noise at the reviewed boundary should pass: #{stderr}")

  leaking_bottom_pixels = allowed_bottom_pixels.dup
  leaking_bottom_pixels[[36, 94]] = [17, 17, 17]
  leaking_bottom_path = File.join(directory, "leaking-next-page.bmp")
  build_bitmap(leaking_bottom_path, leaking_bottom_pixels)
  _stdout, stderr, status = run_validator(leaking_bottom_path)
  assert_exit_status(status, 65, "next-page content in the headline bottom central band")
  assert(stderr.include?("found 22 nonblack pixels, maximum 21"), "headline leakage rejection should expose its evidence")

  complete_second_row_tail = recent_pixels.merge(
    (94...96).flat_map { |y| (15...85).map { |x| [[x, y], [41, 41, 41]] } }.to_h,
  )
  complete_second_row_tail_path = File.join(directory, "complete-second-row-tail.bmp")
  build_bitmap(complete_second_row_tail_path, complete_second_row_tail)
  _stdout, stderr, status = run_validator(
    complete_second_row_tail_path,
    frame: "watchos-recent-reports",
  )
  assert(status.success?, "a complete second-row tail before the final review band should pass: #{stderr}")

  _stdout, stderr, status = run_validator(complete_second_row_tail_path, frame: "watchos-headline")
  assert_exit_status(status, 65, "the same bottom tail on the headline route")
  assert(stderr.include?("next-page leakage in the bottom central band"), "headline must continue to review the whole band")

  reviewed_boundary_pixels = complete_second_row_tail.merge(
    (15...29).to_h { |x| [[x, 96], [41, 41, 41]] },
  )
  reviewed_boundary_path = File.join(directory, "recent-reviewed-boundary.bmp")
  build_bitmap(reviewed_boundary_path, reviewed_boundary_pixels)
  stdout, stderr, status = run_validator(reviewed_boundary_path, frame: "watchos-recent-reports")
  assert(status.success?, "14 reviewed recent bottom pixels should pass: #{stderr}")
  assert(stdout.include?("bottom central band 14/14 nonblack pixels in rows 96...99"), "accepted recent telemetry should expose its exact bottom boundary")

  reviewed_overflow_pixels = complete_second_row_tail.merge(
    (15...30).to_h { |x| [[x, 96], [41, 41, 41]] },
  )
  reviewed_overflow_path = File.join(directory, "recent-reviewed-overflow.bmp")
  build_bitmap(reviewed_overflow_path, reviewed_overflow_pixels)
  _stdout, stderr, status = run_validator(reviewed_overflow_path, frame: "watchos-recent-reports")
  assert_exit_status(status, 65, "15 pixels at the first reviewed recent bottom row")
  assert(stderr.include?("found 15 nonblack pixels, maximum 14"), "first-row overflow should expose its threshold")
  assert(stderr.include?("reviewed rows 96...99"), "first-row overflow should expose its reviewed rows")

  leaking_recent_pixels = complete_second_row_tail.merge(
    (15...30).to_h { |x| [[x, 99], [41, 41, 41]] },
  )
  leaking_recent_path = File.join(directory, "leaking-recent-next-page.bmp")
  build_bitmap(leaking_recent_path, leaking_recent_pixels)
  _stdout, stderr, status = run_validator(leaking_recent_path, frame: "watchos-recent-reports")
  assert_exit_status(status, 65, "content reappearing at the physical bottom of recent reports")
  assert(stderr.include?("next-page leakage in the bottom central band"), "recent leakage rejection should be explicit")
  assert(stderr.include?("found 15 nonblack pixels, maximum 14"), "recent bottom reappearance should expose its threshold")
  assert(stderr.include?("reviewed rows 96...99"), "recent bottom reappearance should expose its reviewed rows")

  detail_pixels = {}
  (20...30).each do |y|
    (5...20).each { |x| detail_pixels[[x, y]] = [255, 149, 0] }
  end
  detail_path = File.join(directory, "detail.bmp")
  build_bitmap(detail_path, detail_pixels)
  stdout, stderr, status = run_validator(detail_path, frame: "watchos-event-detail")
  assert(status.success?, "detail badge pixels in the route-specific upper band should pass: #{stderr}")
  assert(stdout.include?("150 orange pixels"), "detail validator should report the accepted pixel count")

  detail_with_bottom_content = detail_pixels.merge(
    (94...100).flat_map { |y| (15...85).map { |x| [[x, y], [255, 255, 255]] } }.to_h,
  )
  detail_with_bottom_path = File.join(directory, "detail-with-bottom-content.bmp")
  build_bitmap(detail_with_bottom_path, detail_with_bottom_content)
  stdout, stderr, status = run_validator(detail_with_bottom_path, frame: "watchos-event-detail")
  assert(status.success?, "event-detail semantics must continue to permit ordinary bottom content: #{stderr}")
  assert(stdout.include?("150 orange pixels"), "detail bottom-content validation should preserve badge evidence")

  _stdout, stderr, status = run_validator(detail_path, frame: "watchos-headline")
  assert_exit_status(status, 65, "detail-only upper pixels in the dashboard badge band")
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
  assert_exit_status(status, 65, "top detail banner on the dashboard route")
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
  assert_exit_status(status, 65, "clock-face colors on the headline route")
  assert(stderr.include?("found 0, need 100"), "clock rejection should report zero qualifying pixels")
  _stdout, stderr, status = run_validator(clock_path, frame: "watchos-event-detail")
  assert_exit_status(status, 65, "clock-face colors on the detail route")
  assert(stderr.include?("found 0, need 150"), "detail clock rejection should report zero qualifying pixels")
  assert(stderr.include?("full-frame qualifying orange pixels: 0"), "clock rejection should report full-frame evidence")

  outside_pixels = {}
  (50...60).each do |y|
    (5...15).each { |x| outside_pixels[[x, y]] = [255, 149, 0] }
  end
  outside_path = File.join(directory, "outside-region.bmp")
  build_bitmap(outside_path, outside_pixels)
  _stdout, _stderr, status = run_validator(outside_path)
  assert_exit_status(status, 65, "orange pixels outside the headline content band")
  _stdout, stderr, status = run_validator(outside_path, frame: "watchos-event-detail")
  assert_exit_status(status, 65, "orange pixels below the detail content band")
  assert(stderr.include?("found 0, need 150"), "detail below-band rejection should report zero reviewed pixels")
  assert(stderr.include?("full-frame qualifying orange pixels: 100"), "detail below-band rejection should report full-frame evidence")

  below_threshold_pixels = good_pixels.dup
  below_threshold_pixels.delete([14, 34])
  below_threshold_path = File.join(directory, "below-threshold.bmp")
  build_bitmap(below_threshold_path, below_threshold_pixels)
  _stdout, stderr, status = run_validator(below_threshold_path)
  assert_exit_status(status, 65, "99 qualifying headline pixels")
  assert(stderr.include?("found 99, need 100"), "threshold rejection should report 99 pixels")

  _stdout, stderr, status = run_validator(good_path, width: WIDTH + 1)
  assert_exit_status(status, 70, "bitmap dimension mismatch")
  assert(stderr.include?("unsupported Watch validation bitmap layout"), "dimension failure should identify the layout")

  _stdout, stderr, status = run_validator(good_path, width: "01")
  assert_exit_status(status, 64, "noncanonical expected dimension")
  assert(stderr.include?("expected width must be a canonical positive integer"), "dimension-argument failure should be explicit")

  truncated_path = File.join(directory, "truncated.bmp")
  File.binwrite(truncated_path, File.binread(good_path).byteslice(0, 60))
  _stdout, stderr, status = run_validator(truncated_path)
  assert_exit_status(status, 70, "truncated bitmap")
  assert(stderr.include?("truncated Watch validation bitmap"), "truncation failure should be explicit")

  short_path = File.join(directory, "short.bmp")
  File.binwrite(short_path, "BM")
  _stdout, stderr, status = run_validator(short_path)
  assert_exit_status(status, 70, "too-short bitmap")
  assert(stderr.include?("too short to be a BMP"), "too-short bitmap failure should be explicit")

  not_bitmap_path = File.join(directory, "not-bitmap.bmp")
  File.binwrite(not_bitmap_path, "x" * 54)
  _stdout, stderr, status = run_validator(not_bitmap_path)
  assert_exit_status(status, 70, "non-BMP validation copy")
  assert(stderr.include?("is not a BMP"), "non-BMP failure should be explicit")

  _stdout, stderr, status = run_validator(good_path, frame: "watchos-unreviewed")
  assert_exit_status(status, 64, "unreviewed frame selector")
  assert(stderr.include?("unreviewed Watch frame selector"), "selector failure should be explicit")

  _stdout, stderr, status = run_validator(File.join(directory, "missing.bmp"))
  assert_exit_status(status, 70, "missing validation bitmap")
  assert(stderr.include?("could not read Watch validation bitmap"), "missing bitmap failure should be explicit")
end

puts "Watch foreground badge validator tests passed"
