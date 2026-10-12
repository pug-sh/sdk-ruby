# frozen_string_literal: true

require "logger"

module Pug
  class Log
    PREFIX = "[Pug SDK]"

    def self.describe(error)
      "#{error.class}: #{error.message}"
    end

    def initialize(logger)
      @logger = logger || ::Logger.new($stderr, level: ::Logger::WARN)
    end

    def warn(message)
      write(:warn, message)
    end

    def error(message)
      write(:error, message)
    end

    private

    # A broken logger must not break the never-raises contract of ingestion.
    def write(level, message)
      @logger.public_send(level, "#{PREFIX} #{message}")
      nil
    rescue StandardError
      nil
    end
  end
end
