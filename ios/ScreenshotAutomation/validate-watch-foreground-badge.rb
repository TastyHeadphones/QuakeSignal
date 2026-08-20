#!/usr/bin/ruby

def fail_validation(message, status)
  warn "error: #{message}"
  exit status
end

unless ARGV.length == 4
  fail_validation "usage: validate-watch-foreground-badge.rb <bitmap> <width> <height> <frame-selector>", 64
end

bitmap_path = ARGV.fetch(0)

parse_dimension = lambda do |value, label|
  unless /\A[1-9][0-9]*\z/.match?(value)
    fail_validation "expected #{label} must be a canonical positive integer", 64
  end
  Integer(value, 10)
end

expected_width = parse_dimension.call(ARGV.fetch(1), "width")
expected_height = parse_dimension.call(ARGV.fetch(2), "height")
frame_selector = ARGV.fetch(3)
pixel_area = expected_width * expected_height
dashboard_maximum = [(pixel_area * 12) / 1_000, 100].max
detail_minimum = [(pixel_area * 15) / 1_000, 150].max
recent_minimum = [(pixel_area * 6) / 1_000, 100].max

first_badge_percent, last_badge_percent, minimum_orange_pixels, maximum_orange_pixels = case frame_selector
  when "watchos-headline"
    [20, 45, 100, dashboard_maximum]
  when "watchos-recent-reports"
    [20, 45, recent_minimum, dashboard_maximum]
  when "watchos-event-detail"
    # The detail route places a filled caution banner first inside its
    # ScrollView. Its density distinguishes it from the text-sized
    # dashboard/list badges. The
    # banner begins directly below the navigation title, so include the whole
    # upper content area instead of assuming one safe-area offset.
    [0, 45, detail_minimum, nil]
  else
    fail_validation "unreviewed Watch frame selector", 64
  end

requires_clean_page_bottom = ["watchos-headline", "watchos-recent-reports"].include?(frame_selector)
minimum_badge_rightmost = frame_selector == "watchos-recent-reports" ? (expected_width * 3) / 5 : nil

begin
  data = File.binread(bitmap_path)
rescue SystemCallError => error
  fail_validation "could not read Watch validation bitmap: #{error.message}", 70
end

fail_validation "Watch validation copy is too short to be a BMP", 70 if data.bytesize < 54
fail_validation "Watch validation copy is not a BMP", 70 unless data.byteslice(0, 2) == "BM"

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
  fail_validation "unsupported Watch validation bitmap layout", 70
end

row_stride = ((width * 3 + 3) / 4) * 4
required_size = pixel_offset + row_stride * height
fail_validation "truncated Watch validation bitmap", 70 if data.bytesize < required_size

# The badge occupies a reviewed upper-left content band for each Watch route.
# This tolerance includes antialiasing around CautionColor (#ff9500) without
# admitting the chartreuse/peach numerals on the default clock face.
orange_pixels = 0
full_frame_orange_pixels = 0
orange_rightmost = nil
first_badge_row = (height * first_badge_percent) / 100
last_badge_row = (height * last_badge_percent) / 100
badge_columns = (width * 4) / 5
bottom_band_rows = [(height * 6) / 100, 1].max
first_bottom_row = height - bottom_band_rows
# The complete second report row can occupy the early portion of this band
# after the 44-point refresh control is laid out. A leaked third row instead
# reappears at the physical screen edge, so only reports narrow the scan to
# the final three-fifths. Headline continues to review the whole band.
bottom_review_offset = if frame_selector == "watchos-recent-reports"
  (bottom_band_rows * 2) / 5
else
  0
end
first_reviewed_bottom_row = first_bottom_row + bottom_review_offset
first_bottom_column = (width * 15) / 100
last_bottom_column = (width * 85) / 100
reviewed_bottom_rows = height - first_reviewed_bottom_row
bottom_band_area = reviewed_bottom_rows * (last_bottom_column - first_bottom_column)
maximum_bottom_nonblack_pixels = (bottom_band_area * 5) / 100
bottom_nonblack_pixels = 0

(0...height).each do |display_y|
  storage_y = signed_height.negative? ? display_y : height - 1 - display_y
  row_offset = pixel_offset + storage_y * row_stride
  width.times do |x|
    offset = row_offset + x * 3
    blue = data.getbyte(offset)
    green = data.getbyte(offset + 1)
    red = data.getbyte(offset + 2)

    if requires_clean_page_bottom && display_y >= first_reviewed_bottom_row &&
        x >= first_bottom_column && x < last_bottom_column && [red, green, blue].max > 16
      bottom_nonblack_pixels += 1
    end

    next unless red >= 220 && green.between?(90, 190) && blue <= 60

    full_frame_orange_pixels += 1
    if x < badge_columns && display_y >= first_badge_row && display_y < last_badge_row
      orange_pixels += 1
      orange_rightmost = x if orange_rightmost.nil? || x > orange_rightmost
    end
  end
end

if orange_pixels < minimum_orange_pixels
  if frame_selector == "watchos-recent-reports"
    fail_validation(
      "Watch recent-reports foreground-only label is incomplete " \
      "(found #{orange_pixels} orange pixels, need #{minimum_orange_pixels}; " \
      "rightmost #{orange_rightmost || "none"}, need at least #{minimum_badge_rightmost}); " \
      "full-frame qualifying orange pixels: #{full_frame_orange_pixels}; " \
      "refusing a truncated first viewport",
      65,
    )
  end

  fail_validation(
    "Watch screenshot lacks the orange foreground-only badge " \
    "(found #{orange_pixels}, need #{minimum_orange_pixels} pixels); " \
    "full-frame qualifying orange pixels: #{full_frame_orange_pixels}; " \
    "refusing stale or clock-face capture",
    65,
  )
end
if maximum_orange_pixels && orange_pixels > maximum_orange_pixels
  fail_validation(
    "Watch screenshot has an unexpected orange marker density " \
    "(found #{orange_pixels}, maximum #{maximum_orange_pixels} pixels); " \
    "full-frame qualifying orange pixels: #{full_frame_orange_pixels}; " \
    "refusing a mismatched Watch route",
    65,
  )
end
if minimum_badge_rightmost && (orange_rightmost.nil? || orange_rightmost < minimum_badge_rightmost)
  fail_validation(
    "Watch recent-reports foreground-only label is truncated " \
    "(rightmost orange pixel #{orange_rightmost || "none"}, need at least #{minimum_badge_rightmost}); " \
    "refusing an incomplete first viewport",
    65,
  )
end
if requires_clean_page_bottom && bottom_nonblack_pixels > maximum_bottom_nonblack_pixels
  fail_validation(
    "Watch screenshot has next-page leakage in the bottom central band " \
    "(found #{bottom_nonblack_pixels} nonblack pixels, maximum #{maximum_bottom_nonblack_pixels}; " \
    "reviewed rows #{first_reviewed_bottom_row}...#{height - 1}); " \
    "refusing a clipped first viewport",
    65,
  )
end

if requires_clean_page_bottom
  puts(
    "Validated Watch foreground-only badge: #{orange_pixels} orange pixels; " \
    "bottom central band #{bottom_nonblack_pixels}/#{maximum_bottom_nonblack_pixels} nonblack pixels " \
    "in rows #{first_reviewed_bottom_row}...#{height - 1}",
  )
else
  puts "Validated Watch foreground-only badge: #{orange_pixels} orange pixels"
end
