#!/usr/bin/ruby

require "open3"
require "rbconfig"
require "tmpdir"

VALIDATOR = File.expand_path("validate-vision-map-content.rb", __dir__)
WIDTH = 400
HEIGHT = 240

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

Dir.mktmpdir("quakesignal-vision-map-validator-test.") do |directory|
  valid_path = File.join(directory, "valid.bmp")
  build_bitmap(valid_path) do |x, y|
    if ((x / 8) + (y / 8)) % 17 == 0
      [245, 245, 245]
    else
      red = (x * 3 + y * 5) % 58
      green = 75 + (x * 7 + y * 3) % 150
      blue = 125 + (x * 5 + y * 11) % 125
      [red, green, blue]
    end
  end
  stdout, stderr, status = run_validator(valid_path)
  assert(status.success?, "diverse blue map fixture should pass: #{stderr}")
  assert(stdout.include?("Validated Vision map semantic pixels"), "validator should report accepted metrics")

  blank_path = File.join(directory, "blank.bmp")
  build_bitmap(blank_path) do |x, y|
    shade = 145 + ((x + y) % 18)
    [shade, shade, shade]
  end
  _stdout, stderr, status = run_validator(blank_path)
  assert(!status.success?, "low-diversity gray launch placeholder must fail")
  assert(status.exitstatus == 65, "semantic blank rejection must use status 65")
  assert(stderr.include?("refusing blank launch placeholder"), "blank failure should be explicit")

  grayscale_path = File.join(directory, "grayscale.bmp")
  build_bitmap(grayscale_path) do |x, y|
    shade = ((x / 4 + y / 4).even? ? 20 : 240)
    [shade, shade, shade]
  end
  _stdout, stderr, status = run_validator(grayscale_path)
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

  _stdout, stderr, status = run_validator(valid_path, width: WIDTH + 1)
  assert(!status.success?, "dimension mismatch must fail")
  assert(status.exitstatus == 70, "bitmap dimension mismatch must be operational status 70")
  assert(stderr.include?("unsupported Vision map validation bitmap layout"), "dimension failure should identify layout")

  truncated_path = File.join(directory, "truncated.bmp")
  File.binwrite(truncated_path, File.binread(valid_path).byteslice(0, 60))
  _stdout, stderr, status = run_validator(truncated_path)
  assert(!status.success?, "truncated bitmap must fail")
  assert(status.exitstatus == 70, "truncated bitmap must be operational status 70")
  assert(stderr.include?("truncated Vision map validation bitmap"), "truncation failure should be explicit")

  _stdout, stderr, status = run_validator(valid_path, frame: "visionos-home")
  assert(!status.success?, "validator must reject non-map frame selectors")
  assert(status.exitstatus == 64, "unreviewed selector must be usage status 64")
  assert(stderr.include?("unreviewed Vision frame selector"), "selector failure should be explicit")

  _stdout, stderr, status = run_validator(File.join(directory, "missing.bmp"))
  assert(!status.success?, "missing bitmap must fail")
  assert(status.exitstatus == 70, "missing bitmap must be operational status 70")
  assert(stderr.include?("could not read Vision map validation bitmap"), "missing bitmap failure should be explicit")
end

puts "Vision map semantic validator tests passed"
