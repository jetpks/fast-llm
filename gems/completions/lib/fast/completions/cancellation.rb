# frozen_string_literal: true

require "async"

module Fast
  module Completions
    # Cancellation checkpoints (Specification §11, D8): a no-op outside a
    # reactor; inside one it raises CancelledError when the current
    # Async::Task has been cancelled. Chat calls it before each tool
    # execution and at stream start.
    module Cancellation
      module_function

      def check
        task = Async::Task.current rescue nil
        return unless task&.cancelled?

        raise CancelledError, "current task cancelled"
      end
    end
  end
end
