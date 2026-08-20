#!/usr/bin/ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "pathname"
require "set"
require "tmpdir"
require "zlib"

module QuakeSignalSafeZipTree
  class Error < StandardError; end

  MAX_ARCHIVE_BYTES = 1_073_741_824
  MAX_ENTRY_COUNT = 100_000
  MAX_ENTRY_COMPRESSED_BYTES = 536_870_912
  MAX_ENTRY_UNCOMPRESSED_BYTES = 536_870_912
  MAX_TOTAL_UNCOMPRESSED_BYTES = 1_073_741_824
  INFLATE_INPUT_CHUNK_BYTES = 4_096

  module_function

  def with_safe_extraction(archive:)
    archive_path = canonical_plain_file(archive, "ZIP archive")
    entries = read_entries(archive_path)
    wrappers = entries.map { |entry| entry.fetch(:name).split("/").first }.uniq
    unless wrappers.length == 1 && wrappers.first.end_with?(".xcresult") &&
           entries.any? { |entry| entry.fetch(:name) == "#{wrappers.first}/" && entry.fetch(:type) == :directory } &&
           entries.all? { |entry| entry.fetch(:name).start_with?("#{wrappers.first}/") }
      raise Error, "ZIP must contain exactly one xcresult wrapper"
    end
    stage = Pathname.new(Dir.mktmpdir(".quakesignal-safe-zip.", archive_path.dirname.to_s))
    wrapper = stage.join(wrappers.first)
    begin
      extract_entries(entries, archive_path, stage)
      yield wrapper
    ensure
      FileUtils.remove_entry_secure(stage.to_s) if stage.exist?
    end
  rescue Errno::ENOENT, IOError, SystemCallError => error
    raise Error, "could not safely extract ZIP tree: #{error.message}"
  end

  # Validates a conventional single-wrapper ZIP without invoking an extractor,
  # reconstructs only the already-validated regular entries, and yields the
  # extracted wrapper. Every path, type, mode, size, and file byte must equal
  # the supplied live tree.
  def with_verified_extraction(archive:, source_root:)
    archive_path = canonical_plain_file(archive, "ZIP archive")
    source = canonical_plain_directory(source_root, "ZIP source tree")
    entries = read_entries(archive_path)
    compare_tree(entries, archive_path, source)

    stage = Pathname.new(Dir.mktmpdir(".quakesignal-safe-zip.", archive_path.dirname.to_s))
    wrapper = stage.join(source.basename)
    begin
      extract_entries(entries, archive_path, stage)
      compare_plain_trees(source, wrapper)
      yield wrapper
    ensure
      FileUtils.remove_entry_secure(stage.to_s) if stage.exist?
    end
  rescue Errno::ENOENT, IOError, SystemCallError => error
    raise Error, "could not validate ZIP tree: #{error.message}"
  end

  def extract_entries(entries, archive, stage)
    entries.select { |entry| entry.fetch(:type) == :directory }
           .sort_by { |entry| entry.fetch(:name).count("/") }
           .each do |entry|
      path = stage.join(entry.fetch(:name).delete_suffix("/"))
      path.mkpath
      File.chmod(entry.fetch(:mode) & 0o7777, path)
    end
    entries.select { |entry| entry.fetch(:type) == :file }.each do |entry|
      path = stage.join(entry.fetch(:name))
      path.dirname.mkpath
      path.binwrite(read_entry_bytes(archive, entry))
      File.chmod(entry.fetch(:mode) & 0o7777, path)
    end
  end

  def compare_tree(entries, archive, source)
    prefix = "#{source.basename}/"
    expected_files, expected_directories = tree_inventory(source, prefix)
    actual_files = entries.select { |entry| entry.fetch(:type) == :file }.to_h do |entry|
      [entry.fetch(:name), entry]
    end
    actual_directories = entries.select { |entry| entry.fetch(:type) == :directory }.to_h do |entry|
      [entry.fetch(:name), entry]
    end
    unless actual_files.keys.sort == expected_files.keys.sort &&
           actual_directories.keys.to_set == expected_directories.keys.to_set
      raise Error, "ZIP inventory differs from the retained source tree"
    end
    expected_files.each do |name, path|
      entry = actual_files.fetch(name)
      require_mode(entry, path, name)
      unless entry.fetch(:uncompressed_size) == path.size &&
             Digest::SHA256.hexdigest(read_entry_bytes(archive, entry)) == Digest::SHA256.file(path).hexdigest
        raise Error, "ZIP file bytes differ from the retained source tree: #{name}"
      end
    end
    expected_directories.each do |name, path|
      require_mode(actual_directories.fetch(name), path, name)
    end
  end

  def tree_inventory(root, prefix)
    files = {}
    directories = { prefix => root }
    visit = lambda do |directory|
      directory.children.sort_by(&:to_s).each do |entry|
        stat = entry.lstat
        relative = entry.relative_path_from(root).to_s
        if stat.directory? && !entry.symlink?
          directories["#{prefix}#{relative}/"] = entry
          visit.call(entry)
        elsif stat.file? && !entry.symlink?
          files["#{prefix}#{relative}"] = entry
        else
          raise Error, "source tree contains a symlink or special entry: #{relative}"
        end
      end
    end
    visit.call(root)
    [files, directories]
  end

  def compare_plain_trees(left, right)
    left_files, left_directories = tree_inventory(left, "")
    right_files, right_directories = tree_inventory(right, "")
    unless left_files.keys == right_files.keys && left_directories.keys == right_directories.keys
      raise Error, "safe extracted ZIP inventory changed"
    end
    left_files.each do |relative, source|
      target = right_files.fetch(relative)
      unless (source.lstat.mode & 0o7777) == (target.lstat.mode & 0o7777) &&
             source.size == target.size && Digest::SHA256.file(source).hexdigest == Digest::SHA256.file(target).hexdigest
        raise Error, "safe extracted ZIP file changed: #{relative}"
      end
    end
    left_directories.each do |relative, source|
      target = right_directories.fetch(relative)
      unless (source.lstat.mode & 0o7777) == (target.lstat.mode & 0o7777)
        raise Error, "safe extracted ZIP directory mode changed: #{relative}"
      end
    end
  end

  def require_mode(entry, path, name)
    return if (entry.fetch(:mode) & 0o7777) == (path.lstat.mode & 0o7777)

    raise Error, "ZIP entry mode differs from the retained source tree: #{name}"
  end

  def read_entries(path)
    size = path.size
    raise Error, "archive is not a ZIP" if size < 22
    raise Error, "ZIP archive exceeds the safe byte limit" if size > MAX_ARCHIVE_BYTES

    File.open(path, "rb") do |io|
      tail_size = [size, 65_557].min
      io.seek(size - tail_size)
      tail = io.read(tail_size)
      marker = tail.rindex("PK\x05\x06".b)
      raise Error, "archive is not a ZIP" unless marker

      eocd_offset = size - tail_size + marker
      values = tail.byteslice(marker, 22)&.unpack("VvvvvVVv")
      unless values && values.fetch(0) == 0x06054b50
        raise Error, "ZIP end record is truncated"
      end
      _signature, disk, central_disk, disk_entries, entry_count,
        central_size, central_offset, comment_length = values
      unless disk.zero? && central_disk.zero? && disk_entries == entry_count &&
             entry_count.positive? && entry_count <= MAX_ENTRY_COUNT &&
             comment_length.zero? && eocd_offset + 22 == size &&
             central_offset + central_size == eocd_offset &&
             ![entry_count, central_size, central_offset].include?(0xffff) &&
             ![central_size, central_offset].include?(0xffffffff)
        raise Error, "ZIP must be exact single-disk non-ZIP64 data"
      end

      io.seek(central_offset)
      entries = Array.new(entry_count) do
        header = io.read(46)
        fields = header&.unpack("VvvvvvvVVVvvvvvVV")
        raise Error, "ZIP central entry is malformed" unless fields&.fetch(0) == 0x02014b50

        made_by, needed, flags, method, _time, _date, crc32,
          compressed_size, uncompressed_size, name_length, extra_length,
          entry_comment_length, entry_disk, _internal_attributes,
          external_attributes, local_offset = fields.drop(1)
        if needed >= 45 || entry_disk != 0 || entry_comment_length != 0 ||
           [compressed_size, uncompressed_size, local_offset].include?(0xffffffff) ||
           compressed_size > MAX_ENTRY_COMPRESSED_BYTES ||
           uncompressed_size > MAX_ENTRY_UNCOMPRESSED_BYTES ||
           (flags & ~0x8) != 0 || ![0, 8].include?(method)
          raise Error, "ZIP entry uses unsupported encryption, ZIP64, disk, or compression features"
        end
        name_bytes = io.read(name_length)
        extra = io.read(extra_length)
        unless name_bytes&.bytesize == name_length && extra&.bytesize == extra_length
          raise Error, "ZIP entry metadata is truncated"
        end
        name = name_bytes.dup.force_encoding(Encoding::UTF_8)
        unless name.valid_encoding? && !name.empty? && !name.include?("\0") &&
               !name.include?("\n") && !name.include?("\r") && !name.start_with?("/") &&
               Pathname.new(name.delete_suffix("/")).cleanpath.to_s == name.delete_suffix("/") &&
               name.split("/").none? { |component| component.empty? || component == "." || component == ".." }
          raise Error, "ZIP contains an unsafe path"
        end
        creator = made_by >> 8
        mode = (external_attributes >> 16) & 0xffff
        type_bits = mode & 0o170000
        type = if creator == 3 && type_bits == 0o100000 && !name.end_with?("/")
                 :file
               elsif creator == 3 && type_bits == 0o040000 && name.end_with?("/") && uncompressed_size.zero?
                 :directory
               end
        raise Error, "ZIP contains a symlink, special, or malformed entry: #{name}" unless type
        if type == :directory &&
           (!method.zero? || !crc32.zero? || !compressed_size.zero? || !uncompressed_size.zero?)
          raise Error, "ZIP directory entry must be stored with zero data and checksum: #{name}"
        end

        {
          name: name, type: type, mode: mode, flags: flags, method: method,
          crc32: crc32, compressed_size: compressed_size,
          uncompressed_size: uncompressed_size, local_offset: local_offset,
        }
      end
      raise Error, "ZIP central size is inconsistent" unless io.pos == central_offset + central_size

      names = entries.map { |entry| entry.fetch(:name) }
      offsets = entries.map { |entry| entry.fetch(:local_offset) }
      raise Error, "ZIP contains duplicate entries" unless names.uniq.length == names.length && offsets.uniq.length == offsets.length
      if entries.sum { |entry| entry.fetch(:uncompressed_size) } > MAX_TOTAL_UNCOMPRESSED_BYTES
        raise Error, "ZIP expanded tree exceeds the safe byte limit"
      end

      validate_local_layout(io, entries, central_offset)
      entries
    end
  end

  def validate_local_layout(io, entries, central_offset)
    ordered = entries.sort_by { |entry| entry.fetch(:local_offset) }
    raise Error, "ZIP contains prefix bytes" unless ordered.first&.fetch(:local_offset) == 0

    ordered.each_with_index do |entry, index|
      io.seek(entry.fetch(:local_offset))
      fields = io.read(30)&.unpack("VvvvvvVVVvv")
      raise Error, "ZIP local entry is malformed" unless fields&.fetch(0) == 0x04034b50

      _signature, needed, flags, method, _time, _date, local_crc,
        local_compressed, local_uncompressed, name_length, extra_length = fields
      local_name = io.read(name_length)
      local_extra = io.read(extra_length)
      unless needed < 45 && local_name&.bytesize == name_length &&
             local_extra&.bytesize == extra_length &&
             local_name == entry.fetch(:name).b && flags == entry.fetch(:flags) &&
             method == entry.fetch(:method)
        raise Error, "ZIP local/central entry metadata mismatch"
      end
      central_sizes = [entry.fetch(:crc32), entry.fetch(:compressed_size), entry.fetch(:uncompressed_size)]
      local_sizes = [local_crc, local_compressed, local_uncompressed]
      sizes_valid = if (flags & 0x8).zero?
                      local_sizes == central_sizes
                    else
                      local_sizes == [0, 0, 0] || local_sizes == central_sizes
                    end
      raise Error, "ZIP local/central entry sizes mismatch" unless sizes_valid
      if entry.fetch(:type) == :directory && local_sizes != [0, 0, 0]
        raise Error, "ZIP local directory entry must contain zero sizes and checksum"
      end

      data_end = entry.fetch(:local_offset) + 30 + name_length + extra_length + entry.fetch(:compressed_size)
      next_offset = index + 1 < ordered.length ? ordered.fetch(index + 1).fetch(:local_offset) : central_offset
      descriptor_size = next_offset - data_end
      allowed = (entry.fetch(:flags) & 0x8).zero? ? [0] : [12, 16]
      raise Error, "ZIP contains an unaccounted local-entry gap" unless allowed.include?(descriptor_size)
      next if descriptor_size.zero?

      io.seek(data_end)
      descriptor = io.read(descriptor_size)
      descriptor_values = descriptor_size == 16 ? descriptor&.unpack("VVVV") : descriptor&.unpack("VVV")
      descriptor_values = descriptor_values.drop(1) if descriptor_size == 16 && descriptor_values&.first == 0x08074b50
      unless descriptor_values == [entry.fetch(:crc32), entry.fetch(:compressed_size), entry.fetch(:uncompressed_size)]
        raise Error, "ZIP data descriptor is inconsistent"
      end
    end
  end

  def read_entry_bytes(path, entry)
    File.open(path, "rb") do |io|
      io.seek(entry.fetch(:local_offset))
      fields = io.read(30)&.unpack("VvvvvvVVVvv")
      raise Error, "ZIP local entry is malformed" unless fields&.fetch(0) == 0x04034b50

      _signature, _needed, flags, method, _time, _date, local_crc,
        local_compressed, local_uncompressed, name_length, extra_length = fields
      name = io.read(name_length)
      io.seek(extra_length, IO::SEEK_CUR)
      unless name == entry.fetch(:name).b && flags == entry.fetch(:flags) && method == entry.fetch(:method)
        raise Error, "ZIP local/central entry mismatch"
      end
      if (flags & 0x8).zero? && [local_crc, local_compressed, local_uncompressed] !=
         [entry.fetch(:crc32), entry.fetch(:compressed_size), entry.fetch(:uncompressed_size)]
        raise Error, "ZIP local sizes mismatch"
      end
      expected_compressed = entry.fetch(:compressed_size)
      expected_uncompressed = entry.fetch(:uncompressed_size)
      if method.zero? && expected_compressed != expected_uncompressed
        raise Error, "stored ZIP entry compressed/uncompressed sizes differ"
      end
      bytes = String.new(encoding: Encoding::BINARY)
      checksum = 0
      append_output = lambda do |chunk|
        if bytes.bytesize + chunk.bytesize > expected_uncompressed ||
           bytes.bytesize + chunk.bytesize > MAX_ENTRY_UNCOMPRESSED_BYTES
          raise Error, "ZIP entry expanded beyond its declared or safe byte limit"
        end
        bytes << chunk
        checksum = Zlib.crc32(chunk, checksum)
      end
      remaining = expected_compressed
      inflater = method == 8 ? Zlib::Inflate.new(-Zlib::MAX_WBITS) : nil
      begin
        while remaining.positive?
          chunk = io.read([remaining, INFLATE_INPUT_CHUNK_BYTES].min)
          raise Error, "ZIP entry data is truncated" unless chunk && !chunk.empty?
          remaining -= chunk.bytesize
          if inflater
            if inflater.finished?
              raise Error, "ZIP deflate stream contains trailing or concatenated data"
            end
            append_output.call(inflater.inflate(chunk))
          else
            append_output.call(chunk)
          end
        end
        if inflater
          unless inflater.finished? && inflater.total_in == expected_compressed
            raise Error, "ZIP deflate stream contains trailing or concatenated data"
          end
          append_output.call(inflater.finish)
        end
      ensure
        inflater&.close
      end
      unless bytes.bytesize == expected_uncompressed && checksum == entry.fetch(:crc32)
        raise Error, "ZIP entry checksum mismatch"
      end
      bytes
    end
  rescue Zlib::Error => error
    raise Error, "ZIP entry could not be decoded: #{error.message}"
  end

  def canonical_plain_file(value, label)
    path = Pathname.new(value).expand_path
    unless Pathname.new(value).absolute? && path.realpath == path && path.file? && !path.symlink?
      raise Error, "#{label} must be a canonical absolute plain file"
    end
    path
  end

  def canonical_plain_directory(value, label)
    path = Pathname.new(value).expand_path
    unless Pathname.new(value).absolute? && path.realpath == path && path.directory? && !path.symlink?
      raise Error, "#{label} must be a canonical absolute plain directory"
    end
    path
  end
end
