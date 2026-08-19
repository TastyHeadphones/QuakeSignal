#!/usr/bin/ruby

def fail_validation(message)
  abort "error: #{message}"
end

unless ARGV.length == 4
  fail_validation "usage: validate-watch-foreground-badge.rb <bitmap> <width> <height> <frame-selector>"
end

bitmap_path = ARGV.fetch(0)

parse_dimension = lambda do |value, label|
  unless /\A[1-9][0-9]*\z/.match?(value)
    fail_validation "expected #{label} must be a canonical positive integer"
  end
  Integer(value, 10)
end

expected_width = parse_dimension.call(ARGV.fetch(1), "width")
expected_height = parse_dimension.call(ARGV.fetch(2), "height")
frame_selector = ARGV.fetch(3)
pixel_area = expected_width * expected_height
dashboard_maximum = [(pixel_area * 12) / 1_000, 100].max
detail_minimum = [(pixel_area * 15) / 1_000, 150].max

first_badge_percent, last_badge_percent, minimum_orange_pixels, maximum_orange_pixels = case frame_selector
  when "watchos-headline", "watchos-recent-reports"
    [20, 45, 100, dashboard_maximum]
  when "watchos-event-detail"
    # The detail route pins a filled caution banner above its ScrollView. Its
    # density distinguishes it from the text-sized dashboard/list badges.
    [15, 40, detail_minimum, nil]
  else
    fail_validation "unreviewed Watch frame selector"
  end

begin
  data = File.binread(bitmap_path)
rescue SystemCallError => error
  fail_validation "could not read Watch validation bitmap: #{error.message}"
end

fail_validation "Watch validation copy is too short to be a BMP" if data.bytesize < 54
fail_validation "Watch validation copy is not a BMP" unless data.byteslice(0, 2) == "BM"

pixel_offset = data.byteslice(10, 4).unpack1("V")
dib_size = data.byteslice(14, 4).unpack1("V")
width = data.byteslice(18, 4).unpack1("l<")
signed_height = data.byteslice(22, 4).unpack1("l<")
planes = data.byteslice(26, 2).unpack1("v")
bits_per_pixel = data.byteslice(28, 2).unpack1("v")
compression = data.byteslice(30, 4).unpack1("V")
height = signed_height.abs

unless dib_size >= 40 && width == expected_width && height == expected_height &&
    signed_height != 0 && planes == 1 && bits_per_pixel == 24 && compression.zero? &&
    pixel_offset >= 14 + dib_size
  fail_validation "unsupported Watch validation bitmap layout"
end

row_stride = ((width * 3 + 3) / 4) * 4
required_size = pixel_offset + row_stride * height
fail_validation "truncated Watch validation bitmap" if data.bytesize < required_size

# The badge occupies a reviewed upper-left content band for each Watch route.
# This tolerance includes antialiasing around CautionColor (#ff9500) without
# admitting the chartreuse/peach numerals on the default clock face.
orange_pixels = 0
first_badge_row = (height * first_badge_percent) / 100
last_badge_row = (height * last_badge_percent) / 100
badge_columns = (width * 4) / 5

(first_badge_row...last_badge_row).each do |display_y|
  storage_y = signed_height.negative? ? display_y : height - 1 - display_y
  row_offset = pixel_offset + storage_y * row_stride
  badge_columns.times do |x|
    offset = row_offset + x * 3
    blue = data.getbyte(offset)
    green = data.getbyte(offset + 1)
    red = data.getbyte(offset + 2)
    orange_pixels += 1 if red >= 220 && green.between?(90, 190) && blue <= 60
  end
end

if orange_pixels < minimum_orange_pixels
  fail_validation(
    "Watch screenshot lacks the orange foreground-only badge " \
    "(found #{orange_pixels}, need #{minimum_orange_pixels} pixels); " \
    "refusing stale or clock-face capture",
  )
end
if maximum_orange_pixels && orange_pixels > maximum_orange_pixels
  fail_validation(
    "Watch screenshot has an unexpected orange marker density " \
    "(found #{orange_pixels}, maximum #{maximum_orange_pixels} pixels); " \
    "refusing a mismatched Watch route",
  )
end

puts "Validated Watch foreground-only badge: #{orange_pixels} orange pixels"
