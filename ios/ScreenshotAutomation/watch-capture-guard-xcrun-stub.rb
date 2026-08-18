#!/usr/bin/ruby

mode = ARGV.fetch(1)
Signal.trap("TERM", "IGNORE") if ENV.fetch("QUAKESIGNAL_TEST_IGNORE_TERM", "0") == "1"
case mode
when "io"
  File.write(ENV.fetch("QUAKESIGNAL_TEST_CAPTURE_PID_FILE"), "#{Process.pid}\n")
  delay = Integer(ENV.fetch("QUAKESIGNAL_TEST_CAPTURE_DELAY"), 10)
  status = Integer(ENV.fetch("QUAKESIGNAL_TEST_CAPTURE_STATUS"), 10)
when "launch"
  abort "restart must use --terminate-running-process" unless ARGV.fetch(2) == "--terminate-running-process"
  File.write(ENV.fetch("QUAKESIGNAL_TEST_REACTIVATION_PID_FILE"), "#{Process.pid}\n")
  File.write(ENV.fetch("QUAKESIGNAL_TEST_REACTIVATION_MARKER"), "restarted\n")
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
