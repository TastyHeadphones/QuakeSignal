#!/usr/bin/ruby
# frozen_string_literal: true

require "json"
require "digest"
require "pathname"
require "securerandom"
require "time"

module QuakeSignalIOSScreenshotSimulatorLease
  class Error < StandardError; end

  class DuplicateRejectingHash < Hash
    def []=(key, value)
      raise Error, "duplicate simulator lease JSON key #{key.inspect}" if key?(key)
      super
    end
  end

  module_function

  def create(path:, source_commit:, token:, owner_pid:, simulators:)
    output = new_path(path)
    validate_commit(source_commit)
    validate_token(token)
    validate_pid(owner_pid)
    unless simulators.is_a?(Array) && (1..2).cover?(simulators.length) &&
           simulators.map { |item| item.fetch("displayClass") }.uniq.length == simulators.length
      raise Error, "simulator lease must describe one or two unique display classes"
    end
    normalized = simulators.map do |item|
      exact_keys(item, %w[displayClass name runtimeIdentifier deviceTypeIdentifier], "simulator lease specification")
      item.each_value { |value| require_nonempty(value, "simulator lease specification") }
      item.merge("deviceIdentifier" => nil)
    end
    record = {
      "schemaVersion" => 1,
      "status" => "active-disposable-ios-screenshot-simulator-lease",
      "sourceCommit" => source_commit,
      "token" => token,
      "ownerProcessId" => owner_pid,
      "simulators" => normalized,
    }
    write_exclusive(output, record)
    record
  rescue KeyError, TypeError => error
    raise Error, "invalid simulator lease specification: #{error.message}"
  end

  def assign(path:, token:, display_class:, device_identifier:)
    lease_path, record = load(path)
    validate_active(record, token: token)
    validate_udid(device_identifier)
    matches = record.fetch("simulators").select { |item| item.fetch("displayClass") == display_class }
    raise Error, "simulator lease display class is not unique" unless matches.length == 1
    entry = matches.first
    if !entry.fetch("deviceIdentifier").nil? && entry.fetch("deviceIdentifier") != device_identifier
      raise Error, "simulator lease already binds a different device"
    end
    entry["deviceIdentifier"] = device_identifier
    atomic_replace(lease_path, record)
    record
  end

  def verify_reuse(path:, source_commit:, token:, owner_pid:, display_class:, name:, device_identifier:,
                   runtime_identifier:, device_type_identifier:)
    _lease_path, record = load(path)
    validate_active(record, token: token)
    unless record.fetch("sourceCommit") == source_commit && record.fetch("ownerProcessId") == owner_pid
      raise Error, "reused simulator is not owned by the invoking parent capture set"
    end
    expected = {
      "displayClass" => display_class,
      "name" => name,
      "runtimeIdentifier" => runtime_identifier,
      "deviceTypeIdentifier" => device_type_identifier,
      "deviceIdentifier" => device_identifier,
    }
    matches = record.fetch("simulators").select { |item| item == expected }
    raise Error, "reused simulator does not match its exact parent-owned lease" unless matches.length == 1
    true
  end

  def resolve(path:, token:, devices_source:, display_class:)
    _lease_path, record = load(path)
    validate_active(record, token: token)
    lease_entries = record.fetch("simulators").select { |item| item.fetch("displayClass") == display_class }
    raise Error, "simulator lease display class is not unique" unless lease_entries.length == 1
    expected = lease_entries.first
    devices = parse_object(devices_source, "simctl devices").fetch("devices")
    candidates = devices.flat_map do |runtime, entries|
      Array(entries).select do |entry|
        runtime == expected.fetch("runtimeIdentifier") &&
          entry.fetch("name", nil) == expected.fetch("name") &&
          entry.fetch("deviceTypeIdentifier", nil) == expected.fetch("deviceTypeIdentifier")
      end
    end
    assigned = expected.fetch("deviceIdentifier")
    candidates.select! { |entry| entry.fetch("udid", nil) == assigned } if assigned
    raise Error, "expected exactly one simulator matching the owned lease" unless candidates.length == 1
    udid = candidates.first.fetch("udid")
    validate_udid(udid)
    udid
  rescue KeyError, TypeError => error
    raise Error, "invalid simulator inventory for lease: #{error.message}"
  end

  def complete(path:, token:, lease_evidence:, absence_evidence_directory:, evidence_output:, verified_at:)
    lease_path, record = load(path)
    validate_active(record, token: token)
    retained_lease = canonical_plain_file(lease_evidence, "retained simulator lease evidence")
    unless retained_lease.binread == lease_path.binread && retained_lease.basename.to_s == "simulator-lease-evidence.json"
      raise Error, "retained simulator lease evidence differs from the active owned lease"
    end
    absence_root = canonical_plain_directory(absence_evidence_directory, "simulator absence evidence")
    unless absence_root.basename.to_s == "simulator-absence-evidence"
      raise Error, "simulator absence evidence directory has an unexpected name"
    end
    records = record.fetch("simulators").map do |item|
      udid = item.fetch("deviceIdentifier")
      validate_udid(udid)
      display_class = item.fetch("displayClass")
      unless %w[iphone-6.5 ipad-13].include?(display_class)
        raise Error, "simulator cleanup display class is unreviewed"
      end
      queries = [
        ["deviceIdentifier", udid, "#{display_class}-uuid.json"],
        ["leaseName", item.fetch("name"), "#{display_class}-name.json"],
      ].map do |kind, query, basename|
        snapshot = canonical_plain_file(absence_root.join(basename), "filtered simulator absence snapshot")
        snapshot_record = parse_object(snapshot.read, "filtered simulator absence snapshot")
        exact_keys(snapshot_record, ["devices"], "filtered simulator absence snapshot")
        devices = snapshot_record.fetch("devices")
        unless devices.is_a?(Hash) && devices.values.all? { |entries| entries.is_a?(Array) && entries.empty? }
          raise Error, "filtered simulator absence snapshot still contains a device"
        end
        {
          "kind" => kind,
          "query" => query,
          "file" => "simulator-absence-evidence/#{basename}",
          "sha256" => Digest::SHA256.file(snapshot).hexdigest,
          "exitStatus" => 0,
        }
      end
      item.merge(
        "shutdownRequested" => true,
        "deleteRequested" => true,
        "absentAfterDelete" => true,
        "absenceQueries" => queries,
      )
    end
    Time.iso8601(verified_at)
    evidence = {
      "schemaVersion" => 1,
      "status" => "verified-disposable-ios-simulators-removed-before-publication",
      "sourceCommit" => record.fetch("sourceCommit"),
      "leaseToken" => token,
      "leaseEvidence" => {
        "file" => "simulator-lease-evidence.json",
        "sha256" => Digest::SHA256.file(retained_lease).hexdigest,
      },
      "simulators" => records,
      "verifiedAtUtc" => verified_at,
    }
    output = new_path(evidence_output)
    write_exclusive(output, evidence)
    lease_path.delete
    evidence
  rescue ArgumentError, KeyError, TypeError => error
    raise Error, "invalid simulator cleanup completion: #{error.message}"
  end

  def load(path)
    lease_path = canonical_plain_file(path, "simulator lease")
    parsed = parse_object(lease_path.read, "simulator lease")
    [lease_path, JSON.parse(JSON.generate(parsed))]
  end

  def validate_active(record, token:)
    exact_keys(record, %w[schemaVersion status sourceCommit token ownerProcessId simulators], "simulator lease")
    validate_commit(record.fetch("sourceCommit"))
    validate_token(token)
    validate_pid(record.fetch("ownerProcessId"))
    unless record.fetch("schemaVersion") == 1 &&
           record.fetch("status") == "active-disposable-ios-screenshot-simulator-lease" &&
           secure_equal(record.fetch("token"), token)
      raise Error, "simulator lease is not the exact active owned record"
    end
    simulators = record.fetch("simulators")
    unless simulators.is_a?(Array) && (1..2).cover?(simulators.length)
      raise Error, "simulator lease inventory is invalid"
    end
    simulators.each do |item|
      exact_keys(
        item,
        %w[displayClass name runtimeIdentifier deviceTypeIdentifier deviceIdentifier],
        "simulator lease entry",
      )
      %w[displayClass name runtimeIdentifier deviceTypeIdentifier].each do |key|
        require_nonempty(item.fetch(key), "simulator lease #{key}")
      end
      validate_udid(item.fetch("deviceIdentifier")) unless item.fetch("deviceIdentifier").nil?
    end
  end

  def atomic_replace(path, record)
    temporary = path.dirname.join(".#{path.basename}.#{Process.pid}.#{SecureRandom.hex(8)}.tmp")
    write_exclusive(temporary, record)
    File.rename(temporary, path)
  ensure
    temporary&.delete if temporary&.file? && !temporary.symlink?
  end

  def write_exclusive(path, record)
    File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
      file.write(JSON.pretty_generate(record) + "\n")
      file.flush
      file.fsync
    end
  end

  def new_path(value)
    path = Pathname.new(value).expand_path
    unless Pathname.new(value).absolute? && path.cleanpath == path && path.dirname.realpath == path.dirname &&
           !path.exist? && !path.symlink?
      raise Error, "simulator lease/evidence output must be a new canonical absolute path"
    end
    path
  rescue Errno::ENOENT
    raise Error, "simulator lease/evidence output parent is missing"
  end

  def canonical_plain_file(value, label)
    path = Pathname.new(value).expand_path
    unless Pathname.new(value).absolute? && path.realpath == path && path.lstat.file? && !path.symlink?
      raise Error, "#{label} must be a canonical absolute plain file"
    end
    path
  rescue Errno::ENOENT
    raise Error, "#{label} is missing"
  end

  def canonical_plain_directory(value, label)
    path = Pathname.new(value).expand_path
    unless Pathname.new(value).absolute? && path.realpath == path && path.lstat.directory? && !path.symlink?
      raise Error, "#{label} must be a canonical absolute plain directory"
    end
    path
  rescue Errno::ENOENT
    raise Error, "#{label} is missing"
  end

  def parse_object(source, label)
    value = JSON.parse(source, object_class: DuplicateRejectingHash)
    raise Error, "#{label} must be an object" unless value.is_a?(Hash)
    value
  rescue JSON::ParserError => error
    raise Error, "invalid #{label}: #{error.message}"
  end

  def exact_keys(value, keys, label)
    raise Error, "#{label} has an unexpected schema" unless value.is_a?(Hash) && value.keys.sort == keys.sort
  end

  def secure_equal(left, right)
    return false unless left.is_a?(String) && right.is_a?(String) && left.bytesize == right.bytesize
    left.bytes.zip(right.bytes).reduce(0) { |difference, (a, b)| difference | (a ^ b) }.zero?
  end

  def validate_commit(value)
    raise Error, "lease source commit is invalid" unless value.is_a?(String) && value.match?(/\A[0-9a-f]{40}\z/)
  end

  def validate_token(value)
    raise Error, "simulator lease token is invalid" unless value.is_a?(String) && value.match?(/\A[0-9a-f]{32}\z/)
  end

  def validate_pid(value)
    raise Error, "simulator lease owner PID is invalid" unless value.is_a?(Integer) && value.positive?
  end

  def validate_udid(value)
    raise Error, "simulator device identifier is invalid" unless value.is_a?(String) &&
      value.match?(/\A[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\z/)
  end

  def require_nonempty(value, label)
    raise Error, "#{label} must be nonempty" unless value.is_a?(String) && !value.empty?
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    mode = ARGV.shift
    case mode
    when "create"
      path, commit, token, owner_pid, specs_json = ARGV
      specs = JSON.parse(specs_json)
      QuakeSignalIOSScreenshotSimulatorLease.create(
        path: path, source_commit: commit, token: token, owner_pid: Integer(owner_pid, 10), simulators: specs,
      )
    when "assign"
      path, token, display_class, udid = ARGV
      QuakeSignalIOSScreenshotSimulatorLease.assign(
        path: path, token: token, display_class: display_class, device_identifier: udid,
      )
    when "verify"
      path, commit, token, owner_pid, display_class, name, udid, runtime, device_type = ARGV
      QuakeSignalIOSScreenshotSimulatorLease.verify_reuse(
        path: path, source_commit: commit, token: token, owner_pid: Integer(owner_pid, 10),
        display_class: display_class, name: name, device_identifier: udid,
        runtime_identifier: runtime, device_type_identifier: device_type,
      )
    when "resolve"
      path, token, devices_file, display_class = ARGV
      puts QuakeSignalIOSScreenshotSimulatorLease.resolve(
        path: path, token: token, devices_source: File.read(devices_file), display_class: display_class,
      )
    when "complete"
      path, token, lease_evidence, absence_directory, evidence, verified_at = ARGV
      QuakeSignalIOSScreenshotSimulatorLease.complete(
        path: path, token: token, lease_evidence: lease_evidence,
        absence_evidence_directory: absence_directory, evidence_output: evidence, verified_at: verified_at,
      )
    else
      abort "Usage: ios-screenshot-simulator-lease.rb <create|assign|verify|resolve|complete> ..."
    end
  rescue QuakeSignalIOSScreenshotSimulatorLease::Error, JSON::ParserError, ArgumentError, Errno::ENOENT => error
    warn "error: #{error.message}"
    exit 65
  end
end
