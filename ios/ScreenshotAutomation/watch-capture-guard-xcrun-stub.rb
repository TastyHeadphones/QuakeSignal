#!/usr/bin/ruby

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
  if ENV["SIMCTL_CHILD_QUAKESIGNAL_SCREENSHOT_AUTOMATION"] == "1" &&
      (expected_frame = ENV["QUAKESIGNAL_TEST_EXPECTED_FRAME"])
    abort "restart lost frame environment" unless ENV["SIMCTL_CHILD_QUAKESIGNAL_SCREENSHOT_FRAME"] == expected_frame
    abort "restart lost frame argument" unless ARGV.include?("--quakesignal-screenshot-frame=#{expected_frame}")
  end
  File.write(ENV.fetch("QUAKESIGNAL_TEST_REACTIVATION_PID_FILE"), "#{Process.pid}\n")
  File.write(ENV.fetch("QUAKESIGNAL_TEST_REACTIVATION_MARKER"), "restarted\n")
  wait_for_release.call("QUAKESIGNAL_TEST_REACTIVATION_RELEASE_FILE")
  delay = Integer(ENV.fetch("QUAKESIGNAL_TEST_REACTIVATION_DELAY"), 10)
  status = Integer(ENV.fetch("QUAKESIGNAL_TEST_REACTIVATION_STATUS"), 10)
else
  abort "unexpected xcrun stub mode: #{mode}"
end

if ENV.fetch("QUAKESIGNAL_TEST_SIGNAL_PARENT_MODE", "") == mode
  signal = ENV.fetch("QUAKESIGNAL_TEST_SIGNAL_PARENT", "TERM")
  abort "unsupported parent signal: #{signal}" unless %w[INT TERM].include?(signal)
  Process.kill(signal, Process.ppid)
end

sleep delay
exit status
