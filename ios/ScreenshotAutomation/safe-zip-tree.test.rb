#!/usr/bin/ruby
# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "pathname"
require "tmpdir"
require_relative "safe-zip-tree"
require_relative "screenshot-test-temp-root"

class SafeZipTreeTest < Minitest::Test
  def setup
    @temporary_directory = Dir.mktmpdir(
      "quakesignal-safe-zip-test",
      QuakeSignalScreenshotTestTempRoot.path.to_s,
    )
    @root = Pathname.new(@temporary_directory)
    @wrapper = @root.join("Build.xcresult")
    @wrapper.mkpath
    @wrapper.join("payload.json").write("{\"status\":\"succeeded\"}\n")
    @archive = @root.join("Build.xcresult.zip")
    archive!(@wrapper, @archive)
  end

  def teardown
    FileUtils.remove_entry(@temporary_directory) if @temporary_directory && File.exist?(@temporary_directory)
  end

  def test_accepts_exact_ditto_single_wrapper_archive
    yielded = nil
    QuakeSignalSafeZipTree.with_safe_extraction(archive: @archive) do |root|
      yielded = root.join("payload.json").read
    end
    assert_equal "{\"status\":\"succeeded\"}\n", yielded
  end

  def test_rejects_hidden_trailing_bytes_inside_declared_deflate_payload
    bytes = @archive.binread
    central_offset = eocd_value(bytes, 16)
    file_central = find_central_entry(bytes, central_offset, "Build.xcresult/payload.json")
    compressed_size = value32(bytes, file_central + 20)
    local_offset = value32(bytes, file_central + 42)
    name_length = value16(bytes, local_offset + 26)
    extra_length = value16(bytes, local_offset + 28)
    data_end = local_offset + 30 + name_length + extra_length + compressed_size
    descriptor_signature = value32(bytes, data_end)
    assert_equal 0x08074b50, descriptor_signature

    bytes.insert(data_end, "\0")
    shifted_central = file_central + 1
    shifted_eocd = bytes.rindex("PK\x05\x06".b)
    set32(bytes, data_end + 1 + 8, compressed_size + 1)
    set32(bytes, shifted_central + 20, compressed_size + 1)
    set32(bytes, shifted_eocd + 16, central_offset + 1)
    @archive.binwrite(bytes)

    error = assert_raises(QuakeSignalSafeZipTree::Error) do
      QuakeSignalSafeZipTree.with_safe_extraction(archive: @archive) { |_root| flunk }
    end
    assert_match(/trailing or concatenated data/, error.message)
  end

  def test_rejects_unreviewed_general_purpose_flags
    bytes = @archive.binread
    central_offset = eocd_value(bytes, 16)
    file_central = find_central_entry(bytes, central_offset, "Build.xcresult/payload.json")
    local_offset = value32(bytes, file_central + 42)
    set16(bytes, local_offset + 6, value16(bytes, local_offset + 6) | 0x0800)
    set16(bytes, file_central + 8, value16(bytes, file_central + 8) | 0x0800)
    @archive.binwrite(bytes)

    error = assert_raises(QuakeSignalSafeZipTree::Error) do
      QuakeSignalSafeZipTree.with_safe_extraction(archive: @archive) { |_root| flunk }
    end
    assert_match(/unsupported encryption, ZIP64, disk, or compression features/, error.message)
  end

  def test_rejects_deflated_or_nonempty_directory_records
    {
      "directory compression method" => lambda do |bytes, central, local|
        set16(bytes, central + 10, 8)
        set16(bytes, local + 8, 8)
      end,
      "local directory size" => lambda do |bytes, _central, local|
        set32(bytes, local + 18, 1)
        set32(bytes, local + 22, 1)
      end,
      "local directory name" => lambda do |bytes, _central, local|
        name_length = value16(bytes, local + 26)
        original = bytes.byteslice(local + 30, name_length)
        mutated = original.sub("Build", "Other")
        raise "directory-name mutation changed length" unless mutated.bytesize == original.bytesize
        bytes[local + 30, name_length] = mutated
      end,
    }.each do |label, mutation|
      archive!(@wrapper, @archive)
      bytes = @archive.binread
      central = find_central_entry(bytes, eocd_value(bytes, 16), "Build.xcresult/")
      local = value32(bytes, central + 42)
      mutation.call(bytes, central, local)
      @archive.binwrite(bytes)

      error = assert_raises(QuakeSignalSafeZipTree::Error, label) do
        QuakeSignalSafeZipTree.with_safe_extraction(archive: @archive) { |_root| flunk }
      end
      assert_match(/directory entry|local\/central entry|local directory entry/, error.message, label)
    end
  end

  def test_rejects_deflate_expansion_beyond_declared_size_while_streaming
    bytes = @archive.binread
    central_offset = eocd_value(bytes, 16)
    central = find_central_entry(bytes, central_offset, "Build.xcresult/payload.json")
    local = value32(bytes, central + 42)
    flags = value16(bytes, central + 8)
    compressed_size = value32(bytes, central + 20)
    set32(bytes, central + 24, 1)
    if (flags & 0x8).zero?
      set32(bytes, local + 22, 1)
    else
      name_length = value16(bytes, local + 26)
      extra_length = value16(bytes, local + 28)
      descriptor = local + 30 + name_length + extra_length + compressed_size
      if value32(bytes, descriptor) == 0x08074b50
        set32(bytes, descriptor + 12, 1)
      else
        set32(bytes, descriptor + 8, 1)
      end
    end
    @archive.binwrite(bytes)

    error = assert_raises(QuakeSignalSafeZipTree::Error) do
      QuakeSignalSafeZipTree.with_safe_extraction(archive: @archive) { |_root| flunk }
    end
    assert_match(/expanded beyond its declared or safe byte limit/, error.message)
  end

  private

  def archive!(source, destination)
    success = system(
      "/usr/bin/ditto", "-c", "-k", "--norsrc", "--keepParent",
      source.to_s, destination.to_s,
      out: File::NULL, err: File::NULL,
    )
    raise "could not create test ZIP" unless success && destination.file?
  end

  def find_central_entry(bytes, offset, name)
    cursor = offset
    loop do
      raise "central entry not found" unless value32(bytes, cursor) == 0x02014b50

      name_length = value16(bytes, cursor + 28)
      extra_length = value16(bytes, cursor + 30)
      comment_length = value16(bytes, cursor + 32)
      return cursor if bytes.byteslice(cursor + 46, name_length) == name

      cursor += 46 + name_length + extra_length + comment_length
    end
  end

  def eocd_value(bytes, relative_offset)
    value32(bytes, bytes.rindex("PK\x05\x06".b) + relative_offset)
  end

  def value16(bytes, offset)
    bytes.byteslice(offset, 2).unpack1("v")
  end

  def value32(bytes, offset)
    bytes.byteslice(offset, 4).unpack1("V")
  end

  def set16(bytes, offset, value)
    bytes[offset, 2] = [value].pack("v")
  end

  def set32(bytes, offset, value)
    bytes[offset, 4] = [value].pack("V")
  end
end
