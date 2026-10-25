# frozen_string_literal: true

module Fast
  module Completions
    # The telemetry observation protocol (I01): a sink includes this
    # module and overrides what it wants — the defaults are no-ops. No
    # base class, no respond_to? dispatch at notification time (Client
    # validates the five hooks ONCE at construction, the only sanctioned
    # respond_to? use); duck-typed sinks that define all five are
    # accepted without including the module.
    #
    # Unit of observation: a COMPLETION — ONE Client#stream invocation
    # (one logical request-response on POST {base}/chat/completions with
    # stream: true). Creation retries are INSIDE the completion (a
    # retried completion is one completion); tool execution (the Chat
    # batch) is OUTSIDE it.
    #
    # All hook arguments are existing references or immediates — no Hash
    # payloads, no structs, no interpolated strings, no keyword splats —
    # so dispatching to a no-op sink allocates nothing on the hot paths.
    module Telemetry
      # A sink includes this module and overrides what it wants. The
      # defaults are no-ops. No base class; no respond_to? dispatch at
      # notification time.
      module Sink
        # Exactly once per completion, before the first POST of the
        # first attempt. `model_id` is the Model#id String ref
        # (equal?-stable, never a copy); `request_bytes` is the Integer
        # bytesize of the serialized request body actually POSTed.
        def on_completion_start(model_id, request_bytes); end

        # At most once, at the FIRST item the SSE parser yields for the
        # SUCCESSFUL (2xx) attempt — measured from that attempt's POST
        # initiation (a retried attempt's clock restarts). Seconds since
        # the POST, a Float. Does not fire when the completion fails
        # before any item.
        def on_completion_ttfb(seconds); end

        # Every Event the consumer block sees, BEFORE the consumer
        # block, same order — terminals (:done, :error) and the
        # salvage-path :error included; with a registered sink but no
        # consumer block, sinks still receive every Event produced at
        # the yield sites. The argument is the Event ref the accumulator
        # already allocated.
        def on_event(event); end

        # Exactly once, when Client#stream returns: after the :done
        # event's dispatches. `stop_reason` is the mapped Symbol (:stop,
        # :length, :tool_use); `duration` is the Float from the
        # completion-start clock; `message` is the accumulator's LIVE
        # assistant Message (see the read-only convention in
        # docs/reference/telemetry.md).
        def on_completion_end(stop_reason, duration, message); end

        # Exactly once on EVERY raise-out of Client#stream — the mapped
        # paths and any other raise re-raised through the ladder.
        # `error` is a Symbol derived from the raising class
        # (demodulized, underscored: :rate_limit_error,
        # :connection_error, :timeout_error, :cancelled_error,
        # :stream_error, :runtime_error, …); `duration` is the Float
        # start-to-raise on the same completion-start clock.
        def on_completion_error(error, duration); end
      end
    end
  end
end
