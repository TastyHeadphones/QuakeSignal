#!/usr/bin/ruby

REVIEWED_FRAME_SELECTORS = %w[
  visionos-home
  visionos-reports
  visionos-map
  visionos-guide
  visionos-alert-preferences
].freeze

# Every reviewed route must contain a committed app-panel frame rather than the
# low-contrast launch card that visionOS can leave visible after process launch.
# These common thresholds are intentionally below the weakest retained Guide
# and Alert Preferences captures while remaining above both observed launch
# placeholders. The map adds stricter, route-specific evidence below.
MINIMUM_READY_LUMA_STANDARD_DEVIATION = 25.0
MINIMUM_READY_EDGE_FRACTION = 0.01
MINIMUM_MAP_LUMA_STANDARD_DEVIATION = 28.0
MINIMUM_MAP_QUANTIZED_COLOR_BINS = 80
MINIMUM_MAP_SATURATED_FRACTION = 0.15
MINIMUM_MAP_BLUE_FRACTION = 0.03
MINIMUM_MAP_BRIGHT_FRACTION = 0.0005
MINIMUM_MAP_EDGE_FRACTION = 0.0075
SAMPLE_STRIDE = 4

def fail_validation(message, status)
  warn "error: #{message}"
  exit status
end

unless ARGV.length == 4
  fail_validation "usage: validate-vision-map-content.rb <bitmap> <width> <height> <frame-selector>", 64
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
unless REVIEWED_FRAME_SELECTORS.include?(frame_selector)
  fail_validation "unreviewed Vision frame selector", 64
end

begin
  data = File.binread(bitmap_path)
rescue SystemCallError => error
  fail_validation "could not read Vision validation bitmap: #{error.message}", 70
end

fail_validation "Vision validation copy is too short to be a BMP", 70 if data.bytesize < 54
fail_validation "Vision validation copy is not a BMP", 70 unless data.byteslice(0, 2) == "BM"

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
  fail_validation "unsupported Vision validation bitmap layout", 70
end

row_stride = ((width * 3 + 3) / 4) * 4
required_size = pixel_offset + row_stride * height
fail_validation "truncated Vision validation bitmap", 70 if data.bytesize < required_size

# The Vision app window consistently occupies this central field. Sampling
# inside it excludes the room background and checks committed application
# content rather than accepting a launch placeholder with valid 4K dimensions.
first_x = (width * 30) / 100
last_x = (width * 70) / 100
first_y = (height * 28) / 100
last_y = (height * 73) / 100

sample_count = 0
luma_sum = 0.0
luma_squared_sum = 0.0
saturated_count = 0
map_blue_count = 0
bright_count = 0
quantized_bins = {}
edge_count = 0
edge_comparisons = 0
previous_row_luma = {}

(first_y...last_y).step(SAMPLE_STRIDE) do |display_y|
  storage_y = signed_height.negative? ? display_y : height - 1 - display_y
  row_offset = pixel_offset + storage_y * row_stride
  current_row_luma = {}

  (first_x...last_x).step(SAMPLE_STRIDE).each_with_index do |x, sample_x|
    offset = row_offset + x * 3
    blue = data.getbyte(offset)
    green = data.getbyte(offset + 1)
    red = data.getbyte(offset + 2)
    luma = 0.2126 * red + 0.7152 * green + 0.0722 * blue

    sample_count += 1
    luma_sum += luma
    luma_squared_sum += luma * luma
    saturated_count += 1 if [red, green, blue].max - [red, green, blue].min >= 35
    map_blue_count += 1 if blue >= 70 && blue - red >= 25 && green - red >= 5
    bright_count += 1 if luma >= 215
    quantized_bins[(red >> 4) << 8 | (green >> 4) << 4 | (blue >> 4)] = true

    if sample_x.positive?
      edge_comparisons += 1
      edge_count += 1 if (luma - current_row_luma.fetch(sample_x - 1)).abs >= 24
    end
    if previous_row_luma.key?(sample_x)
      edge_comparisons += 1
      edge_count += 1 if (luma - previous_row_luma.fetch(sample_x)).abs >= 24
    end
    current_row_luma[sample_x] = luma
  end

  previous_row_luma = current_row_luma
end

if sample_count.zero? || edge_comparisons.zero?
  fail_validation "Vision validation region has no samples", 70
end

mean_luma = luma_sum / sample_count
variance = luma_squared_sum / sample_count - mean_luma * mean_luma
luma_standard_deviation = Math.sqrt([variance, 0.0].max)
saturated_fraction = saturated_count.fdiv(sample_count)
map_blue_fraction = map_blue_count.fdiv(sample_count)
bright_fraction = bright_count.fdiv(sample_count)
edge_fraction = edge_count.fdiv(edge_comparisons)

metrics = format(
  "luma sd %.2f, q16 bins %d, saturated %.2f%%, map-blue %.2f%%, bright %.3f%%, edges %.3f%%",
  luma_standard_deviation,
  quantized_bins.length,
  saturated_fraction * 100,
  map_blue_fraction * 100,
  bright_fraction * 100,
  edge_fraction * 100,
)

valid_ready_frame = luma_standard_deviation >= MINIMUM_READY_LUMA_STANDARD_DEVIATION &&
  edge_fraction >= MINIMUM_READY_EDGE_FRACTION

valid_map_route = luma_standard_deviation >= MINIMUM_MAP_LUMA_STANDARD_DEVIATION &&
  quantized_bins.length >= MINIMUM_MAP_QUANTIZED_COLOR_BINS &&
  saturated_fraction >= MINIMUM_MAP_SATURATED_FRACTION &&
  map_blue_fraction >= MINIMUM_MAP_BLUE_FRACTION &&
  (bright_fraction >= MINIMUM_MAP_BRIGHT_FRACTION ||
    edge_fraction >= MINIMUM_MAP_EDGE_FRACTION)
valid_route = frame_selector != "visionos-map" || valid_map_route

unless valid_ready_frame && valid_route
  route_requirement = if frame_selector == "visionos-map"
    "Vision map lacks reviewed semantic pixel diversity"
  else
    "Vision frame #{frame_selector} lacks reviewed app-panel pixel structure"
  end
  fail_validation(
    "#{route_requirement} (#{metrics}); refusing blank launch placeholder",
    65,
  )
end

puts "Validated Vision frame semantic pixels for #{frame_selector}: #{metrics}"
