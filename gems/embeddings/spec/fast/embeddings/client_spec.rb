# frozen_string_literal: true

# Client pins: the closed two-key body, wire-order data, the per-call
# credentials law, the one-attempt discipline, and the cancel-vs-deadline
# ladder — live against the gem's own MockEmbeddingsServer.
require "fast/embeddings"
require_relative "../../support/mock_embeddings_server"

RSpec.describe Fast::Embeddings::Client do
  let(:server) { MockEmbeddingsServer.new.start }
  let(:vectors) { [[0.1, 0.25, -3.5], [1.5, -2.0, 0.0]] }

  after { server.stop }

  def client(**overrides)
    described_class.new(base_url: server.url, **overrides)
  end

  # Runs one two-text embed call in the caller's reactor and returns the
  # Result (or re-raises). The key is PER CALL; the client retires with
  # the call.
  def embed(c = nil, api_key: nil, **overrides)
    c ||= client
    Async do
      begin
        c.embed(model: "mock-model", input: ["hello", "world"], api_key: api_key, **overrides)
      ensure
        c.close
      end
    end.wait
  end

  it "POSTs {base}/embeddings with authorization/content-type/accept headers" do
    server.script([{type: :embeddings, vectors: vectors}])
    embed(api_key: "test-key")
    entry = server.captured_request_logs.first
    expect(entry[:path]).to eq("/v1/embeddings")
    expect(entry[:method]).to eq("POST")
    expect(entry[:headers]["authorization"]).to eq("Bearer test-key")
    expect(entry[:headers]["content-type"]).to eq("application/json")
    expect(entry[:headers]["accept"]).to eq("application/json")
  end

  it "sends NO authorization header without a key, and none for an empty-string key" do
    server.script([{type: :embeddings, vectors: vectors}, {type: :embeddings, vectors: vectors}])
    embed # nil key
    embed(api_key: "") # the local-engine case: present but empty → no header
    logs = server.captured_request_logs
    expect(logs[0][:headers]).not_to have_key("authorization")
    expect(logs[1][:headers]).not_to have_key("authorization")
  end

  it "sends the CLOSED two-key body {model, input} in that key order — no other keys ever" do
    server.script([{type: :embeddings, vectors: vectors}])
    embed
    body = server.captured_requests.first
    expect(body.keys).to eq(["model", "input"])
    expect(body["model"]).to eq("mock-model")
    expect(body["input"]).to eq(["hello", "world"])
  end

  it "surfaces Result.data in WIRE ORDER with verbatim numbers and indices" do
    server.script([{type: :embeddings, vectors: vectors, index_order: [1, 0]}])
    result = embed
    # The wire's data array arrived [index 1, index 0] — surfaced as-is,
    # never re-sorted by index; the caller zips by index.
    expect(result.data.map(&:index)).to eq([1, 0])
    expect(result.data[0].embedding).to eq(vectors[1]) # verbatim: no Float coercion
    expect(result.data[1].embedding).to eq(vectors[0])
    expect(result.data).to all(be_a(Fast::Embeddings::Datum))
  end

  it "surfaces Result.usage from the wire" do
    server.script([{type: :embeddings, vectors: vectors,
                    usage: {prompt_tokens: 7, total_tokens: 9}}])
    expect(embed.usage).to eq(Fast::Embeddings::Usage.new(prompt_tokens: 7, total_tokens: 9))
  end

  it "surfaces ZERO usage when the wire omits the usage key" do
    server.script([{type: :embeddings, vectors: vectors}]) # no usage key at all
    expect(embed.usage).to eq(Fast::Embeddings::Usage::ZERO)
  end

  it "raises ArgumentError when constructed with api_key: (keys are per call)" do
    expect { described_class.new(base_url: server.url, api_key: "k") }
      .to raise_error(ArgumentError, /unknown keyword/)
  end

  it "retains no credential material on the instance after a call" do
    server.script([{type: :embeddings, vectors: vectors}])
    c = client
    embed(c, api_key: "sekret-key-material")
    # Structural: the construction kwargs are base_url/timeout only — the
    # full ivar set can never hold a key; the scan double-pins the value.
    expect(c.instance_variables).to eq(%i[@endpoint @timeout @client @path])
    expect(c.instance_variables.none? { |v| c.instance_variable_get(v).to_s.include?("sekret") }).to be(true)
  end

  it "enforces the input contract: non-Array / empty / non-String entry / bare String each raise" do
    c = client
    Async do
      expect { c.embed(model: "m", input: "hello") }.to raise_error(ArgumentError, /non-empty Array of Strings/)
      expect { c.embed(model: "m", input: []) }.to raise_error(ArgumentError, /non-empty Array of Strings/)
      expect { c.embed(model: "m", input: ["a", 2]) }.to raise_error(ArgumentError, /non-empty Array of Strings/)
      expect { c.embed(model: "m", input: "hello") }.to raise_error(ArgumentError) # the bare String: the caller wraps
      c.close
    end
    expect(server.captured_request_logs).to be_empty # refused before the wire
  end

  it "enforces the model contract: empty or non-String model raises" do
    c = client
    Async do
      expect { c.embed(model: "", input: ["x"]) }.to raise_error(ArgumentError, /non-empty String/)
      expect { c.embed(model: 42, input: ["x"]) }.to raise_error(ArgumentError, /non-empty String/)
      c.close
    end
    expect(server.captured_request_logs).to be_empty
  end

  it "crosses a two-text input VERBATIM — no slicing, no truncation, no re-ordering" do
    server.script([{type: :embeddings, vectors: vectors}])
    input = ["longer first text", "second text"]
    embed(client, input: input)
    expect(server.captured_requests.first["input"]).to eq(input) # same Array contents, same order
  end

  it "makes exactly ONE attempt on a 500 — one captured request, ServerError, no retry" do
    server.script([{type: :error, status: 500, message: "boom"}])
    c = client
    Async do
      expect { c.embed(model: "mock-model", input: ["hello", "world"]) }
        .to raise_error(Fast::Embeddings::ServerError, /500: boom/)
    ensure
      c.close
    end
    expect(server.captured_request_logs.size).to eq(1)
  end

  it "maps connection refusal to ConnectionError with the network message form" do
    dead = described_class.new(base_url: "http://127.0.0.1:1/v1") # nothing listens on port 1
    Async do
      expect { dead.embed(model: "m", input: ["x"]) }
        .to raise_error(Fast::Embeddings::ConnectionError, /Errno::ECONNREFUSED/)
    ensure
      dead.close
    end
  end

  it "raises TimeoutError when the server never responds within the deadline" do
    server.script([{type: :never_respond}])
    c = client(timeout: 0.15)
    Async do
      expect { c.embed(model: "mock-model", input: ["hello", "world"]) }
        .to raise_error(Fast::Embeddings::TimeoutError, /no data within 0.15s/)
    ensure
      c.close
    end
  end

  it "raises CancelledError on a user cancel (watchdog not fired)" do
    server.script([{type: :never_respond}])
    outcome = nil
    c = client # default timeout: the deadline is NOT what fires here
    Async do |task|
      worker = task.async do
        outcome = begin
          c.embed(model: "m", input: ["x"])
          :no_raise
        rescue Fast::Embeddings::CancelledError
          :cancelled
        end
      end
      200.times do # deterministic handshake: cancel only after the POST reached the wire
        break if server.request_logs.size >= 1

        task.sleep 0.01
      end
      worker.cancel
    end
    expect(outcome).to eq(:cancelled)
    expect(server.request_logs.size).to eq(1) # Queue#size: non-destructive count
  ensure
    c.close
  end

  it "raises ResponseError on a 200 that is not JSON" do
    server.script([{type: :raw, status: 200, body: "<html>not json</html>"}])
    c = client
    Async do
      expect { c.embed(model: "mock-model", input: ["hello", "world"]) }
        .to raise_error(Fast::Embeddings::ResponseError, /not JSON/)
    ensure
      c.close
    end
  end

  it "raises ResponseError when the 200 data is not an Array" do
    server.script([{type: :raw, status: 200, body: '{"object":"list","data":"nope"}'}])
    c = client
    Async do
      expect { c.embed(model: "mock-model", input: ["hello", "world"]) }
        .to raise_error(Fast::Embeddings::ResponseError, /not an Array of/)
    ensure
      c.close
    end
  end

  it "raises ResponseError when a data entry carries no Array embedding" do
    server.script([{type: :raw, status: 200, body: '{"data":[{"index":0}]}'}])
    c = client
    Async do
      expect { c.embed(model: "mock-model", input: ["hello", "world"]) }
        .to raise_error(Fast::Embeddings::ResponseError, /not an Array of/)
    ensure
      c.close
    end
  end

  it "raises ResponseError when a data entry carries no Integer index" do
    server.script([{type: :raw, status: 200, body: '{"data":[{"embedding":[0.1],"index":"0"}]}'}])
    c = client
    Async do
      expect { c.embed(model: "mock-model", input: ["hello", "world"]) }
        .to raise_error(Fast::Embeddings::ResponseError, /not an Array of/)
    ensure
      c.close
    end
  end

  it "validates timeout at construction: 0, -1, and \"x\" each raise ArgumentError" do
    expect { described_class.new(base_url: server.url, timeout: 0) }.to raise_error(ArgumentError, /positive Numeric/)
    expect { described_class.new(base_url: server.url, timeout: -1) }.to raise_error(ArgumentError, /positive Numeric/)
    expect { described_class.new(base_url: server.url, timeout: "x") }.to raise_error(ArgumentError, /positive Numeric/)
  end

  it "exposes the frozen timeout (attr_reader) and the DEFAULT_TIMEOUT constant" do
    expect(described_class::DEFAULT_TIMEOUT).to eq(30)
    expect(client.timeout).to eq(30)
    expect(client(timeout: 2.5).timeout).to eq(2.5)
  end
end
