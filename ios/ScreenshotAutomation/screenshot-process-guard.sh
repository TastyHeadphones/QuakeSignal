#!/bin/bash

# Recursively enumerate one exact child process tree. Callers retain the root
# PID in `quakesignal_screenshot_active_child_pid` so EXIT/HUP/INT/TERM cleanup can
# stop and reap compilers, builds, captures, validators, or child harnesses.
quakesignal_screenshot_process_tree() {
  local process_id="$1"
  local child_id
  for child_id in $(/usr/bin/pgrep -P "$process_id" 2>/dev/null || true); do
    quakesignal_screenshot_process_tree "$child_id"
  done
  printf '%s\n' "$process_id"
}

quakesignal_screenshot_stop_processes() {
  local requested_id
  local process_id
  local any_live=0
  local attempt=0
  local process_ids=("")

  for requested_id in "$@"; do
    if [ -n "$requested_id" ] && kill -0 "$requested_id" >/dev/null 2>&1; then
      while IFS= read -r process_id; do
        process_ids+=("$process_id")
      done < <(quakesignal_screenshot_process_tree "$requested_id")
    elif [ -n "$requested_id" ]; then
      process_ids+=("$requested_id")
    fi
  done
  for process_id in "${process_ids[@]}"; do
    if [ -n "$process_id" ] && kill -0 "$process_id" >/dev/null 2>&1; then
      kill -TERM "$process_id" >/dev/null 2>&1 || true
    fi
  done
  while [ "$attempt" -lt 20 ]; do
    any_live=0
    for process_id in "${process_ids[@]}"; do
      if [ -n "$process_id" ] && kill -0 "$process_id" >/dev/null 2>&1; then
        any_live=1
        break
      fi
    done
    [ "$any_live" -eq 0 ] && break
    sleep 0.1
    attempt=$((attempt + 1))
  done
  for process_id in "${process_ids[@]}"; do
    if [ -n "$process_id" ] && kill -0 "$process_id" >/dev/null 2>&1; then
      kill -KILL "$process_id" >/dev/null 2>&1 || true
    fi
  done
  for process_id in "${process_ids[@]}"; do
    if [ -n "$process_id" ]; then
      wait "$process_id" >/dev/null 2>&1 || true
    fi
  done
}

quakesignal_screenshot_defer_spawn_signals() {
  quakesignal_screenshot_saved_int_trap="$(trap -p INT)"
  quakesignal_screenshot_saved_term_trap="$(trap -p TERM)"
  quakesignal_screenshot_saved_hup_trap="$(trap -p HUP)"
  quakesignal_screenshot_deferred_signal=""
  trap 'quakesignal_screenshot_deferred_signal=INT' INT
  trap 'quakesignal_screenshot_deferred_signal=TERM' TERM
  trap 'quakesignal_screenshot_deferred_signal=HUP' HUP
}

quakesignal_screenshot_restore_spawn_signals() {
  if [ -n "$quakesignal_screenshot_saved_int_trap" ]; then
    eval "$quakesignal_screenshot_saved_int_trap"
  else
    trap - INT
  fi
  if [ -n "$quakesignal_screenshot_saved_term_trap" ]; then
    eval "$quakesignal_screenshot_saved_term_trap"
  else
    trap - TERM
  fi
  if [ -n "$quakesignal_screenshot_saved_hup_trap" ]; then
    eval "$quakesignal_screenshot_saved_hup_trap"
  else
    trap - HUP
  fi
  case "$quakesignal_screenshot_deferred_signal" in
    INT) exit 130 ;;
    TERM) exit 143 ;;
    HUP) exit 129 ;;
  esac
}

quakesignal_screenshot_run_tracked() {
  if [ "$#" -eq 0 ]; then
    return 64
  fi
  local spawned_pid
  local child_status=0

  quakesignal_screenshot_defer_spawn_signals
  "$@" &
  spawned_pid=$!
  if [ "${QUAKESIGNAL_TEST_HOLD_SCREENSHOT_PID_ASSIGNMENT:-0}" = "1" ]; then
    sleep 1 || true
  fi
  quakesignal_screenshot_active_child_pid="$spawned_pid"
  quakesignal_screenshot_restore_spawn_signals

  if wait "$quakesignal_screenshot_active_child_pid"; then
    child_status=0
  else
    child_status=$?
  fi
  quakesignal_screenshot_active_child_pid=""
  return "$child_status"
}

# Returns the device/inode identity of one canonical plain directory. Capture
# scripts bind the publication parent, temporary root, and payload separately.
quakesignal_screenshot_capture_directory_identity() {
  [ "$#" -eq 1 ] || return 64
  /usr/bin/ruby -rpathname -e '
    path = Pathname.new(ARGV.fetch(0))
    stat = path.lstat
    abort "directory is not canonical" unless
      path.absolute? && path.cleanpath == path && !path.symlink? && stat.directory? && path.realpath == path
    puts "#{stat.dev}:#{stat.ino}"
  ' "$1"
}

quakesignal_screenshot_capture_parent_identity() {
  quakesignal_screenshot_capture_directory_identity "$@"
}

quakesignal_screenshot_parent_identity_matches() {
  [ "$#" -eq 2 ] || return 64
  local actual_identity
  actual_identity="$(quakesignal_screenshot_capture_parent_identity "$1" 2>/dev/null)" || return 1
  [ "$actual_identity" = "$2" ]
}

# Removes only a canonical tree reached relative to the still-bound original
# parent. A replaced parent is rejected before any path beneath it is touched.
quakesignal_screenshot_remove_bound_tree() {
  [ "$#" -eq 4 ] || return 64
  /usr/bin/ruby -rfileutils -rpathname -rsecurerandom -rfiddle/import -e '
    module DarwinBoundCleanup
      extend Fiddle::Importer
      dlload Fiddle.dlopen(nil)
      extern "int renameatx_np(int, const char *, int, const char *, unsigned int)"
      extern "int openat(int, const char *, int)"
    end
    rename_exclusive_nofollow = 0x4 | 0x10
    open_directory_nofollow = 0x00100000 | 0x00000100
    fd_path = lambda do |fd|
      io = IO.for_fd(fd, autoclose: false)
      buffer = "\0" * 1_024
      io.fcntl(50, buffer)
      Pathname.new(buffer.split("\0", 2).first)
    end
    open_relative_directory = lambda do |directory_fd, name|
      fd = DarwinBoundCleanup.openat(directory_fd, name, open_directory_nofollow)
      raise SystemCallError.new("openat", Fiddle.last_error) if fd.negative?
      IO.for_fd(fd)
    end
    target = Pathname.new(ARGV.fetch(0))
    parent = Pathname.new(ARGV.fetch(1))
    expected_parent_identity = ARGV.fetch(2)
    expected_target_identity = ARGV.fetch(3)
    abort "bound cleanup paths are not canonical absolute paths" unless
      target.absolute? && target.cleanpath == target &&
      parent.absolute? && parent.cleanpath == parent
    relative = target.relative_path_from(parent)
    abort "bound cleanup target must be one direct child of its parent" unless
      relative.each_filename.to_a.length == 1
    parent_directory = Dir.open(parent)
    target_io = nil
    begin
      parent_io = IO.for_fd(parent_directory.fileno, autoclose: false)
      parent_stat = parent_io.stat
      identity = "#{parent_stat.dev}:#{parent_stat.ino}"
      abort "bound cleanup parent identity changed" unless
        parent_stat.directory? && identity == expected_parent_identity && fd_path.call(parent_directory.fileno) == parent
      target_io = open_relative_directory.call(parent_directory.fileno, relative.to_s)
      target_stat = target_io.stat
      target_identity = "#{target_stat.dev}:#{target_stat.ino}"
      abort "bound cleanup target is not a canonical plain directory" unless
        target_stat.directory? && target_identity == expected_target_identity &&
        fd_path.call(target_io.fileno) == target
      quarantine = ".quakesignal-bound-cleanup-#{SecureRandom.hex(16)}"
      result = DarwinBoundCleanup.renameatx_np(
        parent_directory.fileno, relative.to_s,
        parent_directory.fileno, quarantine,
        rename_exclusive_nofollow,
      )
      raise SystemCallError.new("identity-bound cleanup renameatx_np", Fiddle.last_error) unless result.zero?
      quarantined_io = open_relative_directory.call(parent_directory.fileno, quarantine)
      quarantined_stat = quarantined_io.stat
      quarantined_identity = "#{quarantined_stat.dev}:#{quarantined_stat.ino}"
      unless quarantined_stat.directory? && quarantined_identity == expected_target_identity
        quarantined_io.close
        relative_fd = DarwinBoundCleanup.openat(
          parent_directory.fileno, relative.to_s, open_directory_nofollow,
        )
        relative_absent = relative_fd.negative?
        IO.for_fd(relative_fd).close unless relative_fd.negative?
        if relative_absent
          DarwinBoundCleanup.renameatx_np(
            parent_directory.fileno, quarantine,
            parent_directory.fileno, relative.to_s,
            rename_exclusive_nofollow,
          )
        end
        abort "bound cleanup target identity changed before removal"
      end
      quarantine_path = fd_path.call(quarantined_io.fileno)
      quarantined_io.close
      abort "bound cleanup quarantine escaped its bound parent" unless quarantine_path.dirname == parent
      FileUtils.remove_entry_secure(quarantine_path.to_s)
      remaining_fd = DarwinBoundCleanup.openat(parent_directory.fileno, quarantine, open_directory_nofollow)
      unless remaining_fd.negative?
        IO.for_fd(remaining_fd).close
        abort "bound cleanup quarantine remained"
      end
    ensure
      target_io&.close
      parent_directory.close
    end
  ' "$1" "$2" "$3" "$4"
}

# Atomically renames a payload relative to the already-bound parent directory,
# then rechecks both the parent identity and the canonical published directory.
# If a parent rename/rebind is observed after the rename, the payload is moved
# back relative to the still-open working directory before this function fails.
quakesignal_screenshot_publish_directory() {
  [ "$#" -eq 5 ] || return 64
  /usr/bin/ruby -rpathname -rfiddle/import -e '
    module DarwinExclusiveRename
      extend Fiddle::Importer
      dlload Fiddle.dlopen(nil)
      extern "int renameatx_np(int, const char *, int, const char *, unsigned int)"
      extern "int openat(int, const char *, int)"
    end
    rename_exclusive_nofollow = 0x4 | 0x10
    open_directory_nofollow = 0x00100000 | 0x00000100
    fd_path = lambda do |fd|
      io = IO.for_fd(fd, autoclose: false)
      buffer = "\0" * 1_024
      io.fcntl(50, buffer)
      Pathname.new(buffer.split("\0", 2).first)
    end
    open_relative_directory = lambda do |directory_fd, name|
      fd = DarwinExclusiveRename.openat(directory_fd, name, open_directory_nofollow)
      raise SystemCallError.new("openat", Fiddle.last_error) if fd.negative?
      IO.for_fd(fd)
    end
    payload = Pathname.new(ARGV.fetch(0))
    output = Pathname.new(ARGV.fetch(1))
    expected_parent_identity = ARGV.fetch(2)
    expected_payload_parent_identity = ARGV.fetch(3)
    expected_payload_identity = ARGV.fetch(4)
    parent = output.dirname
    payload_parent = payload.dirname
    abort "publication paths are not canonical absolute paths" unless
      payload.absolute? && payload.cleanpath == payload &&
      output.absolute? && output.cleanpath == output &&
      parent.absolute? && parent.cleanpath == parent &&
      payload_parent.absolute? && payload_parent.cleanpath == payload_parent
    source_parent_relative = payload_parent.relative_path_from(parent)
    abort "payload parent must be one direct child of the publication parent" unless
      source_parent_relative.each_filename.to_a.length == 1
    payload_basename = payload.basename.to_s
    basename = output.basename.to_s
    published = false
    parent_directory = Dir.open(parent)
    payload_parent_directory = Dir.open(payload_parent)
    payload_io = nil
    target_io = nil
    begin
      parent_io = IO.for_fd(parent_directory.fileno, autoclose: false)
      payload_parent_io = IO.for_fd(payload_parent_directory.fileno, autoclose: false)
      parent_stat = parent_io.stat
      parent_identity = "#{parent_stat.dev}:#{parent_stat.ino}"
      abort "publication parent identity changed" unless
        parent_stat.directory? && parent_identity == expected_parent_identity &&
        fd_path.call(parent_directory.fileno) == parent
      payload_parent_stat = payload_parent_io.stat
      payload_parent_identity = "#{payload_parent_stat.dev}:#{payload_parent_stat.ino}"
      abort "payload parent identity changed" unless
        payload_parent_stat.directory? && payload_parent_identity == expected_payload_parent_identity &&
        fd_path.call(payload_parent_directory.fileno) == payload_parent
      payload_io = open_relative_directory.call(payload_parent_directory.fileno, payload_basename)
      payload_stat = payload_io.stat
      payload_identity = "#{payload_stat.dev}:#{payload_stat.ino}"
      abort "payload is not a canonical plain directory" unless
        payload_stat.directory? && payload_identity == expected_payload_identity &&
        fd_path.call(payload_io.fileno) == payload
      existing_target_fd = DarwinExclusiveRename.openat(
        parent_directory.fileno, basename, open_directory_nofollow,
      )
      unless existing_target_fd.negative?
        IO.for_fd(existing_target_fd).close
        abort "publication target already exists"
      end
      hook = ENV["QUAKESIGNAL_TEST_SCREENSHOT_PUBLISH_HOOK"]
      if hook
        abort "screenshot publication hook is test-only" unless
          ENV["QUAKESIGNAL_SCREENSHOT_TEST_HOOKS"] == "1" &&
          Pathname.new(hook).absolute? && File.file?(hook) && !File.symlink?(hook) && File.executable?(hook)
        abort "screenshot publication test hook failed" unless system(hook, payload.to_s, output.to_s)
      end
      begin
        result = DarwinExclusiveRename.renameatx_np(
          payload_parent_directory.fileno, payload_basename,
          parent_directory.fileno, basename,
          rename_exclusive_nofollow,
        )
        raise SystemCallError.new("exclusive publication renameatx_np", Fiddle.last_error) unless result.zero?
        published = true
        target_io = open_relative_directory.call(parent_directory.fileno, basename)
        target_stat = target_io.stat
        target_identity = "#{target_stat.dev}:#{target_stat.ino}"
        current_parent_stat = parent_io.stat
        current_identity = "#{current_parent_stat.dev}:#{current_parent_stat.ino}"
        abort "publication parent changed during atomic rename" unless
          current_parent_stat.directory? && current_identity == expected_parent_identity &&
          fd_path.call(parent_directory.fileno) == parent
        abort "published output is not the exact canonical plain directory" unless
          target_stat.directory? && target_identity == expected_payload_identity &&
          fd_path.call(target_io.fileno) == output
        target_io.close
        target_io = nil
      rescue Exception
        source_fd = DarwinExclusiveRename.openat(
          payload_parent_directory.fileno, payload_basename, open_directory_nofollow,
        )
        source_absent = source_fd.negative?
        IO.for_fd(source_fd).close unless source_fd.negative?
        target_fd = DarwinExclusiveRename.openat(
          parent_directory.fileno, basename, open_directory_nofollow,
        )
        target_present = !target_fd.negative?
        IO.for_fd(target_fd).close unless target_fd.negative?
        if published && source_absent && target_present
          DarwinExclusiveRename.renameatx_np(
            parent_directory.fileno, basename,
            payload_parent_directory.fileno, payload_basename,
            rename_exclusive_nofollow,
          )
        end
        raise
      end
    ensure
      target_io&.close
      payload_io&.close
      payload_parent_directory.close
      parent_directory.close
    end
  ' "$1" "$2" "$3" "$4" "$5"
}
