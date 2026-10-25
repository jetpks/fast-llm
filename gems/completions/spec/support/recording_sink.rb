# frozen_string_literal: true

# I01 test double: a Telemetry::Sink that records every hook into
# caller-supplied arrays plus ONE interleaved timeline tagged :sink (or a
# per-sink tag) / :consumer — the shared timeline is how the specs assert
# the frozen sink-before-consumer ordering per event, and per-sink tags
# assert registration-order dispatch across multiple sinks. The consumer
# block appends its own :consumer entries to the same array.
#
# NOT for the measurement gates: recording allocates by design. The
# gates use a fresh no-op sink (Class.new { include
# Fast::Completions::Telemetry::Sink }.new) whose dispatches allocate
# nothing.
class RecordingSink
  include Fast::Completions::Telemetry::Sink

  def initialize(starts: [], ttfs: [], events: [], ends: [], errors: [], timeline: [], tag: :sink)
    @starts = starts
    @ttfs = ttfs
    @events = events
    @ends = ends
    @errors = errors
    @timeline = timeline
    @tag = tag
  end

  attr_reader :starts, :ttfs, :events, :ends, :errors, :timeline, :tag

  def on_completion_start(model_id, request_bytes)
    @starts << [model_id, request_bytes]
    @timeline << [@tag, :on_completion_start]
  end

  def on_completion_ttfb(seconds)
    @ttfs << seconds
    @timeline << [@tag, :on_completion_ttfb]
  end

  def on_event(event)
    @events << event
    @timeline << [@tag, :on_event, event.type]
  end

  def on_completion_end(stop_reason, duration, message)
    @ends << [stop_reason, duration, message]
    @timeline << [@tag, :on_completion_end, stop_reason]
  end

  def on_completion_error(error, duration)
    @errors << [error, duration]
    @timeline << [@tag, :on_completion_error, error]
  end

  # The hook sequence, timeline order (telemetry entries only).
  def hooks
    @timeline.filter_map { |entry| entry[1] if entry[0] == @tag }
  end

  def event_types
    @events.map(&:type)
  end
end
