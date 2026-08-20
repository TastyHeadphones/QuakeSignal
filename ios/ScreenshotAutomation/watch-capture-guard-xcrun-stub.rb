#!/usr/bin/ruby

if ARGV.length == 6 && ARGV[0, 3] == ["-s", "format", "bmp"] && ARGV[4] == "--out"
  File.binwrite(ARGV.fetch(5), File.binread(ARGV.fetch(3)))
  exit 0
end

if ARGV.length == 4 && ARGV.fetch(0).end_with?(".bmp")
  abort "unexpected Watch frame selector" unless ARGV.fetch(3) == ENV.fetch("QUAKESIGNAL_TEST_EXPECTED_FRAME")
  payload = File.binread(ARGV.fetch(0))
  exit 0 if payload == "valid"
  exit 65 if payload == "invalid"
  exit Integer(ENV.fetch("QUAKESIGNAL_TEST_VALIDATOR_OPERATIONAL_STATUS", "70"), 10)
end

mode = ARGV.fetch(1)
Signal.trap("TERM", "IGNORE") if ENV.fetch("QUAKESIGNAL_TEST_IGNORE_TERM", "0") == "1"

wait_for_release = lambda do |environment_key|
  release_file = ENV.fetch(environment_key, "")
  next if release_file.empty?

  timeout_seconds = Integer(ENV.fetch("QUAKESIGNAL_TEST_RELEASE_TIMEOUT", "20"), 10)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_seconds
  until File.exist?(release_file)
    abort "timed out waiting for test release gate: #{release_file}" if
      Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

    sleep 0.01
  end
end

case mode
when "io"
  File.write(ENV.fetch("QUAKESIGNAL_TEST_CAPTURE_PID_FILE"), "#{Process.pid}\n")
  wait_for_release.call("QUAKESIGNAL_TEST_CAPTURE_RELEASE_FILE")
  delay = Integer(ENV.fetch("QUAKESIGNAL_TEST_CAPTURE_DELAY"), 10)
  status = Integer(ENV.fetch("QUAKESIGNAL_TEST_CAPTURE_STATUS"), 10)
when "launch"
  abort "restart must use --terminate-running-process" unless ARGV.fetch(2) == "--terminate-running-process"
  if (expected_frame = ENV["QUAKESIGNAL_TEST_EXPECTED_FRAME"])
    abort "restart lost automation environment gate" unless
      ENV["SIMCTL_CHILD_QUAKESIGNAL_SCREENSHOT_AUTOMATION"] == "1"
    abort "restart lost frame environment" unless ENV["SIMCTL_CHILD_QUAKESIGNAL_SCREENSHOT_FRAME"] == expected_frame
    abort "restart lost automation argument gate" unless
      ARGV.count("--quakesignal-screenshot-automation") == 1
    abort "restart lost exact frame argument" unless
      ARGV.count("--quakesignal-screenshot-frame=#{expected_frame}") == 1
  end
  File.write(ENV.fetch("QUAKESIGNAL_TEST_REACTIVATION_PID_FILE"), "#{Process.pid}\n")
  reactivation_marker = ENV.fetch("QUAKESIGNAL_TEST_REACTIVATION_MARKER")
  reactivation_count = if File.exist?(reactivation_marker)
    Integer(File.read(reactivation_marker), 10)
  else
    0
  end
  File.write(reactivation_marker, (reactivation_count + 1).to_s)
  wait_for_release.call("QUAKESIGNAL_TEST_REACTIVATION_RELEASE_FILE")
  delay = Integer(ENV.fetch("QUAKESIGNAL_TEST_REACTIVATION_DELAY"), 10)
  status_sequence = ENV.fetch("QUAKESIGNAL_TEST_REACTIVATION_STATUSES", "")
  status = if status_sequence.empty?
    Integer(ENV.fetch("QUAKESIGNAL_TEST_REACTIVATION_STATUS"), 10)
  else
    statuses = status_sequence.split("|", -1)
    Integer(statuses.fetch([reactivation_count, statuses.length - 1].min), 10)
  end
  launch_status_trace = ENV.fetch("QUAKESIGNAL_TEST_LAUNCH_STATUS_TRACE_FILE", "")
  File.open(launch_status_trace, "a") { |file| file.puts(status) } unless launch_status_trace.empty?
else
  abort "unexpected xcrun stub mode: #{mode}"
end

if ENV.fetch("QUAKESIGNAL_TEST_SIGNAL_PARENT_MODE", "") == mode
  signal = ENV.fetch("QUAKESIGNAL_TEST_SIGNAL_PARENT", "TERM")
  abort "unsupported parent signal: #{signal}" unless %w[INT TERM].include?(signal)
  Process.kill(signal, Process.ppid)
end

sleep delay
if mode == "io" && status.zero? && !ENV.fetch("QUAKESIGNAL_TEST_CAPTURE_PAYLOADS", "").empty?
  count_file = ENV.fetch("QUAKESIGNAL_TEST_CAPTURE_COUNT_FILE")
  capture_index = File.exist?(count_file) ? Integer(File.read(count_file), 10) : 0
  payloads = ENV.fetch("QUAKESIGNAL_TEST_CAPTURE_PAYLOADS").split("|", -1)
  payload = payloads.fetch([capture_index, payloads.length - 1].min)
  File.binwrite(ARGV.fetch(-1), payload)
  File.write(count_file, (capture_index + 1).to_s)
end
exit status
