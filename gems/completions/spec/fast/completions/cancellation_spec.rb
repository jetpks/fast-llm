# frozen_string_literal: true

# Cancellation pins (Specification §11, D8): a no-op outside a reactor;
# raises CancelledError when the current async task is cancelled. NOT a
# subclass of Fast::Completions::Error (rescue ladders stay clean).
require "fast/completions"

RSpec.describe Fast::Completions::Cancellation do
  it "is a no-op outside a reactor" do
    expect { described_class.check }.not_to raise_error
  end

  it "passes through an uncancelled task" do
    Async do
      expect { described_class.check }.not_to raise_error
    end
  end

  it "raises CancelledError when the current async task is cancelled" do
    Async do |task|
      task.cancel
      expect { described_class.check }.to raise_error(Fast::Completions::CancelledError)
    end
  end
end

RSpec.describe Fast::Completions::CancelledError do
  it "is a StandardError but NOT under the API error tree (D8)" do
    expect(described_class).to be < StandardError
    expect(described_class).not_to be < Fast::Completions::Error
  end
end
