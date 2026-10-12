# frozen_string_literal: true

module Pug
  class Error < StandardError
    attr_reader :code

    def initialize(message = nil, code: nil)
      @code = code
      super(code ? [code, message].reject { |part| part.to_s.empty? }.join(": ") : message)
    end
  end

  class ClosedError < Error; end

  class QueueOverflowError < Error; end
end
