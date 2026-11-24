# frozen_string_literal: true

require "socket"
require "json"

# Provenance: modeled on fast-completions' spec/support/mock_llm_server.rb
# (the hermetic TCP mock rig lineage: tart test/support at 2943ef0, adapted
# per gem). Same serve-loop skeleton — TCPServer on 127.0.0.1 ephemeral
# port, one request per connection, `Connection: close` declared on every
# responder, TCP_NODELAY on accepted sockets, EPIPE swallowed, request
# logs captured as {method:, path:, headers:, body:} via
# captured_request_logs — adapted to the embeddings wire and its script
# vocabulary.

# A hermetic mock OpenAI-compatible embeddings endpoint over TCP
# (127.0.0.1, ephemeral port): the client under test (Async::HTTP over
# the embeddings wire) talks to it.
#
# Wire details:
# - POST {api_base}/embeddings with a JSON body {model, input: [...]}.
# - Reply: HTTP 200 JSON {"object":"list","data":[{"object":"embedding",
#   "embedding":<vector>,"index":i},...],"model":...,"usage":{...}} — the
#   usage key omitted entirely when the script supplies none.
# - Every response declares `Connection: close`: the mock serves ONE
#   request per connection and closes.
#
# Scripting: pass a list of response specs, each either
#   {type: :embeddings, vectors: [[...], ...], usage: {prompt_tokens:, total_tokens:}}
#     (HTTP 200 with one data entry per vector, index = position;
#      optional index_order: [..] reorders the data ARRAY while keeping
#      each entry's index value — pins the wire-order-vs-index pin)
#   {type: :error, status: 400, message: "..."}
#                                              (HTTP error the client maps
#                                               through the frozen taxonomy)
#   {type: :raw, status: 200, body: "..."}     (the body VERBATIM — malformed-
#                                               reply specs)
#   {type: :never_respond}                     (accept + read the request,
#                                               never reply — deadline specs)
#   {type: :hang_up}                           (close the socket without
#                                               responding — connection-error specs)
# A script-less connection gets a default empty embeddings reply.
class MockEmbeddingsServer
  attr_reader :port, :requests, :request_logs

  def initialize
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @requests = Queue.new
    @request_logs = Queue.new
    @script = []
    @template = []
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
  # (method, path, headers, parsed body) per request.
  def captured_request_logs
    list = []
    list << @request_logs.pop(true) until @request_logs.empty?
    list
  end

  private

  NOTABLE_HEADERS = %w[authorization content-type accept user-agent].freeze

  def serve(io)
    begin
      io.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
    rescue Errno::EINVAL, Errno::EOPNOTSUPP, Errno::ENOPROTOOPT
      nil
    end

    request_line = io.gets
    # A connection that sends no request line (empty TCP connect, prober,
    # port scan) consumes nothing: no script shift, no log entry, no response.
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
      headers: headers.slice(*NOTABLE_HEADERS),
      body: parsed_body,
    }
    @request_logs << entry
    @requests << parsed_body unless parsed_body.nil?

    spec = @script.shift || {type: :embeddings, vectors: [[0.0]]}
    case spec[:type]
    when :error then respond_error(io, spec)
    when :raw then respond_raw(io, spec)
    when :never_respond then sleep 30 # never reply; the test tears it down
    when :hang_up then nil # close without responding (ensure below)
    else respond_embeddings(io, spec)
    end
  rescue Errno::EPIPE
    # The client was torn down mid-response; a dead socket must not
    # pollute suite stderr.
    nil
  ensure
    io.close rescue nil
  end

  def respond_embeddings(io, spec)
    vectors = spec[:vectors]
    entries = vectors.each_with_index.map do |vector, i|
      {"object" => "embedding", "embedding" => vector, "index" => i}
    end
    if spec[:index_order]
      ordered = spec[:index_order].map { |i| entries[i] }
      raise ArgumentError, "index_order must cover every vector exactly once" unless ordered.compact.size == vectors.size

      entries = ordered
    end
    payload = {"object" => "list", "data" => entries, "model" => "mock-model"}
    payload["usage"] = spec[:usage] if spec[:usage] # omitted entirely when not supplied
    out = JSON.generate(payload)
    io.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n" \
      "Content-Length: #{out.bytesize}\r\n\r\n")
    if (frame_bytes = spec[:frames])
      # Framed delivery, the live-transport physics: write the payload in
      # frame_bytes slices, flushing + pausing between them so a single
      # Body#read returns ONE frame (a 1024-dim live reply is ~22KB in
      # ~8KB frames — the 0.1.0 live-read defect's reproduction mode).
      (0...out.bytesize).step(frame_bytes) do |offset|
        io.write(out.byteslice(offset, frame_bytes))
        io.flush
        sleep 0.02
      end
    else
      io.write(out)
    end
  end

  # The body openai-compatible endpoints return on a schema rejection;
  # clients raise on the status before reading anything else.
  def respond_error(io, spec)
    payload = {error: {message: spec[:message], type: "invalid_request_error"}}
    out = JSON.generate(payload)
    status = spec[:status] || 400
    io.write("HTTP/1.1 #{status} Bad Request\r\nContent-Type: application/json\r\nConnection: close\r\n" \
      "Content-Length: #{out.bytesize}\r\n\r\n#{out}")
  end

  def respond_raw(io, spec)
    out = spec[:body].to_s
    status = spec[:status] || 200
    io.write("HTTP/1.1 #{status} OK\r\nContent-Type: application/json\r\nConnection: close\r\n" \
      "Content-Length: #{out.bytesize}\r\n\r\n#{out}")
  end
end
