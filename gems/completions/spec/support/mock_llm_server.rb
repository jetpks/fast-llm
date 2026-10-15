# frozen_string_literal: true

require "socket"
require "json"

# Provenance: copied from tart test/support/mock_llm_server.rb at 2943ef0
# (I02/I17/I29 rig lineage; READ-ONLY copy — tart itself is untouched).
# Adapted for the fast-completions gem: the Tart::Test/TestChat minitest
# nesting and the ruby_llm adapter were REMOVED (the gem has no ruby_llm);
# everything else is behavior-identical — the script vocabulary
# ({type: :stream, content:, reasoning_content:, tool_calls:, chunks:},
# :message, :slow_stream + spec_pause, :error + status), rearm!,
# suppress_usage!, captured_requests/captured_request_logs, the
# empty-connect discipline, and the EPIPE discipline.
#
# A hermetic mock OpenAI-compatible endpoint over TCP (127.0.0.1, ephemeral
# port): the client under test (Async::HTTP over the chat-completions
# wire) talks to it.
#
# Parity-rig extensions (I02), backward compatible:
# - +request_logs+ / +captured_request_logs+: per-request entries
#   {method:, path:, headers:, body:} (the rig evidences which URL path and
#   dialect each app POSTs with, not just the body).
# - +rearm!+: resets the shifting script queue to the template stored by the
#   last +script+ call, so ONE server instance can serve byte-identical
#   responses across runs.
#
# Wire details:
# - POST {api_base}/chat/completions; `stream: true` +
#   `stream_options: {include_usage: true}` when the caller streams.
# - Streaming reply: HTTP 200, `Content-Type: text/event-stream`,
#   chunked transfer; SSE `data: <json>\n\n` lines, each an OpenAI delta
#   ({choices: [{delta: {...}, finish_reason?}]}) plus usage, terminated
#   by `data: [DONE]`.
# - Non-streaming reply: HTTP 200 JSON {choices: [{message: {...},
#   finish_reason}], usage}.
#
# Scripting: pass a list of response specs, each either
#   {type: :stream, content: "text", tool_calls: [{id:, name:, arguments: hash_or_string}]}
#   {type: :stream, reasoning_content: "thinking"}  (a `reasoning_content` delta
#     before the content deltas — the thinking-model wire shape)
#   {type: :stream, chunks: [delta_hashes...]}   (raw deltas, full control)
#   {type: :stream, raw_frames: ["data: ...\n\n", ...]} (VERBATIM wire bytes
#     through the chunked writer, comment lines included — malformed-wire
#     fixtures (I61); NO usage chunk and NO [DONE] are appended, the frames
#     carry exactly what the wire should say)
#   {type: :message, content: "text"}            (non-streaming JSON)
#   {type: :slow_stream, content:, chunk_every:} (streams slowly, for interrupts)
#   {type: :error, status: 400, message: "..."}  (HTTP error the client raises
#     on — the gem maps it through the §8 error tree)
# Every captured request body is pushed to +requests+ (a Queue) for
# assertions; the full per-request wire entry (method, path, notable
# headers, body) goes to +request_logs+ for the parity rig.
class MockLLMServer
  attr_reader :port, :requests, :request_logs

  def initialize
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @requests = Queue.new
    @request_logs = Queue.new
    @script = []
    @template = []
    @accept_thread = nil
    @suppress_usage = false
  end

  # The Case-3 compaction instrument (I29): every response is served
  # WITHOUT the usage payload — non-streaming JSON carries no `usage` key,
  # the stream carries no trailing usage chunk.
  # Scenario-level: set before start, survives rearm!, applies to every
  # scripted response.
  def suppress_usage!
    @suppress_usage = true
    self
  end

  def script(response_specs)
    @template = response_specs.dup
    @script = response_specs.dup
    self
  end

  # Reset the shifting script queue to the template (fresh app, same bytes).
  def rearm!
    @script = @template.dup
    self
  end

  def start
    @accept_thread = Thread.new do
      loop do
        client = @server.accept
        Thread.new(client) { |io| serve(io) }
      end
    rescue StandardError
      nil # socket closed at teardown
    end
    self
  end

  def stop
    @server.close
    @accept_thread&.join(1)
  rescue IOError
    nil
  end

  def url
    "http://127.0.0.1:#{@port}/v1"
  end

  # Drains and returns all captured request bodies (parsed JSON).
  def captured_requests
    list = []
    list << @requests.pop(true) until @requests.empty?
    list
  end

  # Drains and returns all captured request entries: full wire facts
  # (method, path, notable headers, parsed body) per request.
  def captured_request_logs
    list = []
    list << @request_logs.pop(true) until @request_logs.empty?
    list
  end

  private

  NOTABLE_HEADERS = %w[authorization content-type accept user-agent].freeze

  def serve(io)
    request_line = io.gets
    # A connection that sends no request line (empty TCP connect, prober,
    # port scan) consumes nothing: no script shift, no log entry, no response
    # (I17 rig defect: method=None entries shifted every later response by one).
    return if request_line.nil? || request_line.strip.empty?

    headers = {}
    while (line = io.gets) && line != "\r\n"
      name, value = line.split(":", 2)
      headers[name.to_s.strip.downcase] = value.to_s.strip
    end
    body = io.read(headers["content-length"].to_i)
    parsed_body = body.to_s.empty? ? nil : JSON.parse(body)
    entry = {
      method: request_line.to_s.split(" ")[0],
      path: request_line.to_s.split(" ")[1],
      streaming: headers["accept"].to_s.include?("text/event-stream") || body.to_s.include?("\"stream\":true"),
      headers: headers.slice(*NOTABLE_HEADERS),
      body: parsed_body,
    }
    @request_logs << entry
    @requests << parsed_body unless parsed_body.nil?

    spec = @script.shift || {type: :message, content: ""}
    if spec[:type] == :error
      respond_error(io, spec)
    elsif entry[:streaming]
      respond_stream(io, spec)
    else
      respond_message(io, spec)
    end
  rescue Errno::EPIPE
    # The client was torn down mid-response (interrupt tests disconnect
    # mid-stream); a dead socket must not pollute suite stderr (I03
    # backlog carry-in).
    nil
  ensure
    io.close rescue nil
  end

  def respond_message(io, spec)
    payload = {
      choices: [{message: {role: "assistant", content: spec[:content]}, finish_reason: "stop"}],
    }
    payload[:usage] = {prompt_tokens: 10, completion_tokens: 5, total_tokens: 15} unless @suppress_usage
    out = JSON.generate(payload)
    io.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{out.bytesize}\r\n\r\n#{out}")
  end

  # The body openai-compatible endpoints return on a schema rejection;
  # clients raise on the status before any stream is read.
  def respond_error(io, spec)
    payload = {error: {message: spec[:message], type: "invalid_request_error"}}
    out = JSON.generate(payload)
    status = spec[:status] || 400
    io.write("HTTP/1.1 #{status} Bad Request\r\nContent-Type: application/json\r\nContent-Length: #{out.bytesize}\r\n\r\n#{out}")
  end

  def respond_stream(io, spec)
    io.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n")
    if spec[:raw_frames] # I61: verbatim malformed-wire bytes, chunked framing only
      spec[:raw_frames].each { |frame| write_chunk(io, frame) }
    else
      deltas = spec[:type] == :slow_stream ? slow_deltas(spec) : deltas_for(spec)
      deltas.each do |delta|
        write_sse(io, delta)
      end
      write_sse(io, {usage: {prompt_tokens: 10, completion_tokens: 5, total_tokens: 15}}) unless @suppress_usage
      write_chunk(io, "data: [DONE]\n\n")
    end
    io.write("0\r\n\r\n")
  end

  def slow_deltas(spec)
    content = spec[:content]
    deltas = [{choices: [{delta: {role: "assistant"}}]}]
    content.chars.each do |char|
      deltas << {choices: [{delta: {content: char}}]}
      deltas << :pause
    end
    deltas
  end

  def deltas_for(spec)
    return spec[:chunks] if spec[:chunks]

    reasoning = [{choices: [{delta: {reasoning_content: spec[:reasoning_content]}}]}] if spec[:reasoning_content]
    deltas = [*reasoning, {choices: [{delta: {role: "assistant", content: spec[:content] || ""}}]}]
    Array(spec[:tool_calls]).each_with_index do |call, i|
      deltas << {choices: [{delta: {tool_calls: [{index: i, id: call[:id], type: "function",
                                                  function: {name: call[:name], arguments: ""}}]}}]}
      arguments = call[:arguments].is_a?(String) ? call[:arguments] : JSON.generate(call[:arguments])
      deltas << {choices: [{delta: {tool_calls: [{index: i, function: {arguments: arguments}}]}}]}
    end
    deltas << {choices: [{delta: {}, finish_reason: spec[:tool_calls] ? "tool_calls" : "stop"}]}
    deltas
  end

  def write_sse(io, delta)
    if delta == :pause
      sleep(spec_pause) # real inter-chunk delay: the interrupt test races this
      # The keepalive comment must carry proper chunked framing — bare
      # bytes into a chunked stream corrupt the chunk-size lines (raw
      # net/http repro: Net::HTTPBadResponse after the first pause).
      write_chunk(io, ": keepalive\n\n")
      return
    end

    write_chunk(io, "data: #{JSON.generate(delta)}\n\n")
  rescue Errno::EPIPE
    nil
  end

  def write_chunk(io, payload)
    # The client may be torn down mid-stream (interrupt tests disconnect
    # mid-response); writing to a dead socket must not pollute suite
    # stderr with EPIPE noise (I03 backlog carry-in).
    io.write(format("%x\r\n%s\r\n", payload.bytesize, payload))
    io.flush
  rescue Errno::EPIPE
    nil
  end

  def spec_pause
    0.1
  end
end
