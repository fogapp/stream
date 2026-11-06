# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe ToolRunner do
  it "runs a lone argument as a program, never through the shell" do
    Dir.mktmpdir do |dir|
      marker = File.join(dir, "shell-ran")

      # As a lone string Process.spawn would hand this to /bin/sh, which would
      # run both commands; as a program name it names nothing.
      expect { described_class.run([ "true; touch #{marker}" ], timeout: 5) }.to raise_error(Errno::ENOENT)
      expect(File).not_to exist(marker)
    end
  end

  it "passes arguments through untouched, spaces and all" do
    result = described_class.run([ "printf", "%s|", "two words", "$HOME", "*" ], timeout: 5)

    expect(result.stdout).to eq("two words|$HOME|*|")
  end

  it "refuses an empty argv" do
    expect { described_class.run([], timeout: 5) }.to raise_error(ArgumentError)
  end

  it "stops a tool that outlives its timeout" do
    expect { described_class.run(%w[sleep 5], timeout: 1) }.to raise_error(ToolRunner::Timeout)
  end

  describe ".each_line" do
    it "hands over every line, however much output there is" do
      lines = []
      result = described_class.each_line([ "seq", "1", "200000" ], idle_timeout: 5) { |line| lines << line }

      expect(result).to be_success
      expect(lines.size).to eq(200_000) # ~1.3 MB: past .run's 256 KB cap
      expect(lines.values_at(0, -1)).to eq([ "1\n", "200000\n" ])
    end

    it "times a tool by how long it goes quiet, not how long it runs" do
      lines = []
      described_class.each_line([ "sh", "-c", "for i in 1 2 3; do echo $i; sleep 0.6; done" ], idle_timeout: 1) { |line| lines << line }
      expect(lines.size).to eq(3)

      expect { described_class.each_line(%w[sleep 5], idle_timeout: 1) { nil } }
        .to raise_error(ToolRunner::Timeout, /went quiet for 1s/)
    end
  end

  describe ".run_advancing" do
    it "lets a slow tool run as long as its progress keeps moving" do
      script = "for i in 1 2 3 4 5 6; do echo out_time_us=$i; sleep 0.4; done; echo done >&2"
      result = described_class.run_advancing([ "sh", "-c", script ], stall_timeout: 1)

      expect(result).to be_success
      expect(result.stderr).to eq("done\n")
    end

    it "stops a tool that keeps reporting but stands still, and kills it" do
      marker = Rails.root.join("tmp", "run-advancing-#{SecureRandom.hex(4)}")
      script = "while true; do echo out_time_us=7; echo progress=continue; sleep 0.2; done; touch #{marker}"

      expect { described_class.run_advancing([ "sh", "-c", script ], stall_timeout: 1) }
        .to raise_error(ToolRunner::Timeout, /stopped advancing for 1s/)
      sleep 0.5
      expect(marker).not_to exist
    end

    it "counts a read that never starts as standing still" do
      script = "while true; do echo out_time_us=N/A; sleep 0.2; done"
      expect { described_class.run_advancing([ "sh", "-c", script ], stall_timeout: 1) }
        .to raise_error(ToolRunner::Timeout, /stopped advancing/)
    end
  end

  # Someone's watching: the tool stands still, and so does its clock.
  describe "a hold" do
    before { stub_const("ToolRunner::HOLD_POLL", 1) }

    it "stops the tool while the hold says so, without counting it as quiet, and continues it after" do
      holding = false
      Thread.new { sleep 0.5; holding = true; sleep 2; holding = false }
      stamps = []
      script = "for i in 1 2 3 4 5 6 7 8; do echo $i; sleep 0.3; done"

      result = described_class.each_line([ "sh", "-c", script ], idle_timeout: 1, hold: -> { holding }) { stamps << Process.clock_gettime(Process::CLOCK_MONOTONIC) }

      expect(result).to be_success
      expect(stamps.size).to eq(8)
      # The lines before the stop, a gap of the hold's length, then the rest.
      expect(stamps.each_cons(2).map { |a, b| b - a }.max).to be > 1.5
    end

    it "stands still in advancing mode too, then stalls on its own clock" do
      holding = true
      Thread.new { sleep 2; holding = false }
      script = "echo out_time_us=1; while true; do echo out_time_us=1; sleep 0.2; done"

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect { described_class.run_advancing([ "sh", "-c", script ], stall_timeout: 1, hold: -> { holding }) }
        .to raise_error(ToolRunner::Timeout, /stopped advancing for 1s/)
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be > 2.5
    end

    it "gives up on a hold that is never lifted" do
      stub_const("ToolRunner::MAX_HELD", 2)
      script = "echo out_time_us=1; while true; do echo out_time_us=1; sleep 0.2; done"

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect { described_class.run_advancing([ "sh", "-c", script ], stall_timeout: 1, hold: -> { true }) }
        .to raise_error(ToolRunner::Timeout, /held for \d+s without a break/)
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be_between(2, 6)
    end

    it "leaves a tool as it was when the hold can't be read" do
      lines = []
      result = described_class.each_line([ "sh", "-c", "echo a; sleep 0.3; echo b" ], idle_timeout: 2, hold: -> { raise "db away" }) { |line| lines << line }

      expect(result).to be_success
      expect(lines).to eq([ "a\n", "b\n" ])
    end
  end

  it "keeps the end of a streaming tool's stderr, where ffmpeg's summary is" do
    script = "i=0; while [ $i -lt 40000 ]; do echo \"line $i of noise padding padding padding\" >&2; i=$((i+1)); done; echo Summary: last >&2"
    result = described_class.each_line([ "sh", "-c", script ], idle_timeout: 10) { nil }

    expect(result.stderr).to end_with("Summary: last\n")
    expect(result.stderr.bytesize).to be <= ToolRunner::MAX_OUTPUT_BYTES
  end

  describe "the suite's argv guard (spec/support/tool_argv_guard.rb)" do
    it "holds every input to a whitelist of its own" do
      expect { ToolArgvGuard.check!(%w[ffmpeg -protocol_whitelist file -i file:/a -f null -]) }.not_to raise_error
      expect { ToolArgvGuard.check!(%w[nice -n 10 ffmpeg -i file:/a]) }.to raise_error(/no -protocol_whitelist/)
      expect { ToolArgvGuard.check!(%w[ffmpeg -protocol_whitelist file,http -i file:/a]) }.to raise_error(/allows file,http/)
      expect { ToolArgvGuard.check!(%w[ffmpeg -protocol_whitelist file -i file:/a -i file:/b]) }.to raise_error(/no -protocol_whitelist/)
      expect { ToolArgvGuard.check!(%w[ffmpeg -protocol_whitelist http,https,tcp,tls -i {server}/media/n/t/source]) }.not_to raise_error
      expect { ToolArgvGuard.check!(%w[ffmpeg -protocol_whitelist http,https,tcp,tls -i http://evil/x]) }.to raise_error(/allows/)
    end
  end
end
