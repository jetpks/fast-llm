# frozen_string_literal: true

# The incremental tool-args machine (I02) — the frozen live-view contract
# L1-L8 pinned at unit level. This spec is the contract's PROOF, not a
# tripwire: growth, identity stability across deltas, materialization,
# split escapes at every boundary class, partial/invalid \u runs, bad
# escapes, raw control characters, scalar replacement and malformed
# scalars, nested containers, non-object roots, frozen-after-close,
# duplicate keys, surrogate pairs and lones, UTF-8, empty shapes, empty
# fragments — the same ground the spec-side calibration suite (46 checks)
# covered. L9 (events, finalize parity) is pinned by protocol_spec's
# `live view:` examples and the rest of the existing suite.
require "fast/completions"

RSpec.describe Fast::Completions::ArgsStreamer do
  def streamer_for(root)
    described_class.new(root)
  end

  # Consume the fragments one by one; returns the root Hash (the caller's
  # object — identity is part of the contract).
  def live(*fragments)
    root = {}
    streamer = streamer_for(root)
    fragments.each { |fragment| streamer.consume(fragment) }
    root
  end

  # Feed every byte-split of `source` as two fragments and return the
  # results plus the one-shot view (L4: delta boundaries are structural
  # non-events).
  def split_views(source)
    one_shot = live(source)
    bytes = source.b
    (1...bytes.bytesize).map { |cut| live(bytes.byteslice(0, cut), bytes.byteslice(cut, bytes.bytesize - cut)) }
      .unshift(one_shot)
  end

  describe "L1 — identity: one Hash, populated in place, values grow by append" do
    it "populates the caller's Hash object itself, from block creation to finalize" do
      root = {}
      streamer = streamer_for(root)
      streamer.consume('{"path":"li')
      expect(root).to eq({"path" => "li"}) # the SAME object the caller holds
      streamer.consume('ne1"}')
      expect(root).to eq({"path" => "line1"})
    end

    it "an in-flight String value grows by in-place append: a held reference sees it grow" do
      root = {}
      streamer = streamer_for(root)
      streamer.consume('{"path":"a')
      value = root["path"]
      streamer.consume("b.rb")
      expect(root["path"]).to equal(value) # same String object
      expect(value).to eq("ab.rb") # and it grew under the held reference
    end

    it "nested Hashes/Arrays materialize once and are mutated in place, never rebuilt" do
      root = {}
      streamer = streamer_for(root)
      streamer.consume('{"a":{"b":[1,')
      inner_hash = root["a"]
      inner_array = root["a"]["b"]
      streamer.consume('2],"c":{"x":')
      streamer.consume('true}}')
      expect(root).to eq({"a" => {"b" => [1, 2], "c" => {"x" => true}}})
      expect(root["a"]).to equal(inner_hash)
      expect(root["a"]["b"]).to equal(inner_array)
      expect(inner_array[1]).to equal(root["a"]["b"][1])
    end

    it "scalar slots are REPLACED on completion (the L3 exception to in-place growth)" do
      root = {}
      streamer = streamer_for(root)
      streamer.consume('{"n":1')
      raw = root["n"]
      expect(raw).to eq("1") # raw-text String while in flight
      streamer.consume('2,')
      expect(root["n"]).to be(12)
      expect(root["n"]).not_to equal(raw) # the slot was replaced, not mutated
    end
  end

  describe "L2 — shape: string keys, first-appearance order, duplicate collapse" do
    it "keys are escape-decoded string keys in first-appearance order" do
      root = live('{"z":1,"a":"\\n","b":{"c":2}}')
      expect(root.keys).to eq(["z", "a", "b"])
      expect(root).to eq({"z" => 1, "a" => "\n", "b" => {"c" => 2}})
    end

    it "duplicate keys collapse to one slot, last value wins, position is first appearance" do
      root = {}
      streamer = streamer_for(root)
      streamer.consume('{"a":1,"a":')
      expect(root).to eq({"a" => 1}) # first slot, first position
      streamer.consume('"two","z":0,"a":[3]}')
      expect(root).to eq({"a" => [3], "z" => 0})
      expect(root.keys).to eq(["a", "z"])
    end
  end

  describe "L3 — materialization" do
    it "an object value materializes at its opening token, before any content" do
      expect(live('{"a":{')).to eq({"a" => {}})
      expect(live('{"a":{"x"')).to eq({"a" => {}})
    end

    it "an array value materializes at its opening token" do
      expect(live('{"a":[')).to eq({"a" => []})
      expect(live('{"a":[1,')).to eq({"a" => [1]})
    end

    it "a string value materializes at its OPENING quote with \"\" before any content byte" do
      expect(live('{"a":')).to eq({}) # value not opened yet
      expect(live('{"a":"')).to eq({"a" => ""})
      expect(live('{"a":"x')).to eq({"a" => "x"})
    end

    it "a scalar materializes as raw text at its first byte and is classified at termination" do
      expect(live('{"n":1')).to eq({"n" => "1"})
      expect(live('{"n":1.5')).to eq({"n" => "1.5"})
      expect(live('{"n":t')).to eq({"n" => "t"})
      expect(live('{"n":12,')).to eq({"n" => 12})
      expect(live('{"n":-12}')).to eq({"n" => -12})
      expect(live('{"n":1.5}')).to eq({"n" => 1.5})
      expect(live('{"n":-1.5e-2}')).to eq({"n" => -0.015})
      expect(live('{"n":2e10}')).to eq({"n" => 20_000_000_000.0})
      expect(live('{"n":true}')).to eq({"n" => true})
      expect(live('{"n":false}')).to eq({"n" => false})
      expect(live('{"n":null}')).to eq({"n" => nil})
      # whitespace, delimiter, and closers all terminate the token
      expect(live('{"n":1 ,')).to eq({"n" => 1})
      expect(live('{"n":[1]}')).to eq({"n" => [1]})
      expect(live('{"n":{"o":1}}')).to eq({"n" => {"o" => 1}})
    end

    it "a malformed scalar keeps its raw-text String" do
      expect(live('{"a":01}')).to eq({"a" => "01"}) # the frozen clause's own example
      expect(live('{"a":1.}')).to eq({"a" => "1."})
      expect(live('{"a":1.}')).not_to eq({"a" => 1})
      expect(live('{"a":1.e5}')).to eq({"a" => "1.e5"})
      expect(live('{"a":tru}')).to eq({"a" => "tru"})
      expect(live('{"a":tru')).to eq({"a" => "tru"})
      expect(live('{"a":00,"b":1}')).to eq({"a" => "00", "b" => 1})
    end
  end

  describe "L4/L5 — growth and escapes: only new bytes walked, boundaries are non-events" do
    it "every byte-boundary split yields the same live view as the one-shot consume" do
      source = '{"path":"a\\"bA\\n", "n":1.5e2, "s":"\\ud83d\\ude00!é", "z":[true,false,null,01]}'
      views = split_views(source)
      expect(views.first).to eq(
        "path" => "a\"bA\n", "n" => 150.0, "s" => "😀!é", "z" => [true, false, nil, "01"],
      )
      expect(views).to all(eq(views.first))
    end

    it "every byte-boundary split is total over a nastier tail (lone backslash, bad escape, short \\u)" do
      source = '{"k":"\\uD800 tail \\x \\u0 \\ ctrl' + "\x01" + '"}'
      views = split_views(source)
      expect(views.first).to eq({"k" => " tail \\x \\u0 \\ ctrl\u0001"})
      expect(views).to all(eq(views.first))
    end

    it "complete escapes decode immediately" do
      root = {}
      streamer = streamer_for(root)
      streamer.consume('{"a":"x\\')
      expect(root).to eq({"a" => "x"}) # the escape is held, contributing nothing
      streamer.consume('ny"}') # \\n completes inside the second fragment
      expect(root).to eq({"a" => "x\ny"})
    end

    it "a backslash-escape split across deltas: the \\\\ completion appends one backslash" do
      root = {}
      streamer = streamer_for(root)
      streamer.consume('{"a":"x\\')
      streamer.consume('\\y"}')
      expect(root).to eq({"a" => "x\\y"})
    end

    it "a short \\u hex run at a fragment tail is held until completed" do
      root = {}
      streamer = streamer_for(root)
      streamer.consume('{"a":"\\u0')
      expect(root).to eq({"a" => ""}) # nothing contributed yet
      streamer.consume('041"}')
      expect(root).to eq({"a" => "A"})
    end

    it "an invalid escape char contributes literal backslash + char" do
      expect(live('{"a":"x\\qy"}')).to eq({"a" => "x\\qy"})
      root = {}
      streamer = streamer_for(root)
      streamer.consume('{"a":"x\\')
      streamer.consume("qy\"}")
      expect(root).to eq({"a" => "x\\qy"})
    end

    it "an invalidated \\u run contributes literal \\u + the digits collected; the offending byte is content" do
      expect(live('{"a":"\\u12G4"}')).to eq({"a" => "\\u12G4"})
      # short at close: the closing quote invalidates the run
      expect(live('{"a":"\\u12"}')).to eq({"a" => "\\u12"})
    end

    it "raw control characters inside strings contribute literally" do
      expect(live("{\"a\":\"x\ty\"}")).to eq({"a" => "x\ty"})
      expect(live("{\"a\":\"\r\n\"}")).to eq({"a" => "\r\n"})
      expect(live("{\"a\":\"\x01\"}")).to eq({"a" => "\x01"})
    end

    it "a delta boundary splitting an escape is a structural non-event (0.4.0/0.4.1's crash class)" do
      root = {}
      streamer = streamer_for(root)
      expect { streamer.consume('{"path":"li\\') }.not_to raise_error
      expect(root).to eq({"path" => "li"}) # the completed prefix stays live
      expect { streamer.consume('ne1"}') }.not_to raise_error
      expect(root).to eq({"path" => "li\ne1"})
    end
  end

  describe "L6 — surrogates" do
    it "a high escape is held; a following low escape combines into the pair's codepoint" do
      expect(live('{"a":"\\ud83d\\ude00"}')).to eq({"a" => "😀"})
      root = {}
      streamer = streamer_for(root)
      streamer.consume('{"a":"\\ud83d') # held across the delta
      expect(root).to eq({"a" => ""})
      streamer.consume('\\ude00"}')
      expect(root).to eq({"a" => "😀"})
    end

    it "lone surrogate halves NEVER enter the live value" do
      expect(live('{"a":"\\ud83d"}')).to eq({"a" => ""}) # high, pair never lands
      expect(live('{"a":"\\ud83dx"}')).to eq({"a" => "x"}) # high dropped before content
      expect(live('{"a":"\\ud83d\\n"}')).to eq({"a" => "\n"}) # high dropped before another escape
      expect(live('{"a":"\\ude00"}')).to eq({"a" => ""}) # lone low
      expect(live('{"a":"x\\ude00y"}')).to eq({"a" => "xy"})
    end
  end

  describe "L7 — root discipline" do
    it "populates only for an object root; whitespace may lead" do
      expect(live(' {"a":1}')).to eq({"a" => 1})
      expect(live('{ }')).to eq({})
    end

    it "any other root shape leaves the live Hash empty" do
      expect(live('[1,2]')).to eq({})
      expect(live('"scalar"')).to eq({})
      expect(live('true')).to eq({})
      expect(live('123')).to eq({})
      expect(live('garbage{"a":1}')).to eq({}) # garbage before `{`
    end

    it "freezes after the root object closes: later bytes mutate nothing" do
      root = {}
      streamer = streamer_for(root)
      streamer.consume('{"a":1}')
      expect(root).to eq({"a" => 1})
      streamer.consume('{"b":2}more bytes')
      expect(root).to eq({"a" => 1}) # untouched
    end

    it "freezes when the stream becomes unparseable" do
      expect(live('{"a":,')).to eq({})
      expect(live('{"a":1,,')).to eq({"a" => 1}) # trailing comma: frozen with what landed
      expect(live('{"a":}')).to eq({})
      expect(live('{"a" 1}')).to eq({})
      expect(live('{"a":1]')).to eq({"a" => 1}) # wrong closer: frozen
      expect(live('{,}')).to eq({})
      expect(live('{"a":[1,]}')).to eq({"a" => [1]})
      expect(live('{"a":[1,"b",')).to eq({"a" => [1, "b"]})
    end
  end

  describe "L8 — totality and the frozen interface" do
    it "#consume returns self; an empty fragment is a no-op" do
      streamer = streamer_for({})
      expect(streamer.consume("")).to equal(streamer)
      expect(streamer.consume('{"a":1')).to equal(streamer)
      expect(streamer.consume("")).to equal(streamer)
    end

    it "#scratch returns the raw bytes accumulated, for the finalize parse" do
      streamer = streamer_for({})
      streamer.consume('{"path":"a')
      expect(streamer.scratch).to eq('{"path":"a')
      streamer.consume('.rb"}')
      expect(streamer.scratch).to eq('{"path":"a.rb"}')
    end

    it "never raises on any fragment sequence — binary garbage, cut escapes, stray bytes" do
      nasty = [
        ["\xC3", "\xA9"].map { |b| b.b }, # a multibyte char split across binary fragments
        ["\xFF\xFE".b, "\x80".b],        # invalid UTF-8
        ['{"a":"\\'], ["u", "1"],        # escape machinery walked one byte at a time
        ['{"a":'], ["\x00", "\x1F"],
        ["}\\}{", "]\\["],
        ['{"a":"'], ["\\", "u", "d", "8", "3", "d"],
      ]
      expect do
        nasty.each do |frags|
          streamer = streamer_for({})
          frags.each { |fragment| streamer.consume(fragment) }
        end
      end.not_to raise_error
      # a long random-walk torture: any byte stream is survivable (seeded,
      # so a failure reproduces)
      rng = Random.new(20_261_017)
      streamer = streamer_for({})
      expect do
        512.times { streamer.consume((32 + rng.rand(94)).chr + [rng.rand(256)].pack("C")) }
      end.not_to raise_error
    end

    it "invalid UTF-8 content bytes are dropped from the live value (never crash, never flip encodings)" do
      root = {}
      streamer = streamer_for(root)
      streamer.consume('{"a":"x')
      streamer.consume("\xff".b)
      streamer.consume('y"}')
      expect(root).to eq({"a" => "xy"})
      expect(root["a"].encoding).to eq(Encoding::UTF_8)
    end
  end

  describe "UTF-8 and multibyte content" do
    it "multibyte characters never confuse structural ASCII" do
      expect(live('{"a":"héllo"}')).to eq({"a" => "héllo"})
      expect(live('{"a":"日本"}')).to eq({"a" => "日本"})
      expect(live('{"a":"😀"}')).to eq({"a" => "😀"})
    end

    it "a multibyte character split across fragments still assembles" do
      root = {}
      streamer = streamer_for(root)
      streamer.consume('{"a":"h')
      streamer.consume("\xC3".b)
      streamer.consume("\xA9".b)
      streamer.consume('llo"}')
      expect(root).to eq({"a" => "héllo"})
      expect(root["a"].encoding).to eq(Encoding::UTF_8)
    end

    it "escape-decoded multibyte keys stay UTF-8" do
      expect(live('{"a\\u00e9":1}')).to eq({"a\u00e9" => 1})
    end
  end

  describe "empty shapes" do
    it "empty objects, arrays, strings, and the empty stream" do
      expect(live("{}")).to eq({})
      expect(live('{"a":{}}')).to eq({"a" => {}})
      expect(live('{"a":[]}')).to eq({"a" => []})
      expect(live('{"a":""}')).to eq({"a" => ""})
      root = {}
      streamer_for(root)
      expect(root).to eq({}) # no fragment consumed
      expect(live("")).to eq({})
    end
  end
end
