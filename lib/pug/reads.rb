# frozen_string_literal: true

require_relative "connect"
require_relative "errors"
require_relative "rpc"

module Pug
  # Reads run in the caller's control flow: they raise Pug::Error and are never retried.
  module Reads
    def self.call
      yield
    rescue Connect::Passthrough => e
      raise e.error, cause: e.error.cause
    rescue Error
      raise
    rescue StandardError => e
      raise Error, e.message
    end

    class Facade
      def initialize(rpc)
        @rpc = rpc
      end

      private

      def unary(name, request)
        Reads.call { @rpc.unary(name, request) }
      end
    end
  end

  class Profiles < Reads::Facade
    def get(id, include_bots: false)
      unary(:profiles_get, { id: id, **bots(include_bots) }).profile
    end

    def get_by_external_id(external_id, include_bots: false)
      unary(:profiles_get_by_external_id, { external_id: external_id, **bots(include_bots) }).profile
    end

    def delete(id)
      unary(:profiles_delete, { id: id })
    end

    # Auto-paginating: the server streams the pages of one request. The deadline covers the whole
    # stream, the block's time included; timeout (seconds) overrides the client's. Keywords other
    # than timeout are the request, given braceless.
    def list(request = nil, timeout: nil, **fields, &block)
      return enum_for(:list, request, timeout: timeout, **fields) unless block

      Reads.call do
        if request && fields.any?
          raise ArgumentError, "list takes a request or keywords, not both: #{fields.keys.inspect}"
        end
        unless timeout.nil? || Connect.timeout?(timeout)
          raise ArgumentError, "timeout must be a positive number of seconds, got #{timeout.inspect}"
        end

        @rpc.stream(:profiles_list, request || fields, timeout: timeout) { |page| page.profiles.each(&block) }
      end
    end

    private

    def bots(include_bots)
      include_bots ? { include_bots: true } : {}
    end
  end

  class Activity < Reads::Facade
    def feed(request)
      unary(:activity_feed, request)
    end

    def event_explorer(request)
      unary(:activity_event_explorer, request)
    end

    def heatmap(request)
      unary(:activity_heatmap, request)
    end

    def profile_sessions(request)
      unary(:activity_profile_sessions, request)
    end

    def profile_stats(request)
      unary(:activity_profile_stats, request)
    end

    def filter_schema(request = nil)
      unary(:activity_filter_schema, request)
    end

    def property_values(request)
      unary(:activity_property_values, request)
    end
  end

  class Insights < Reads::Facade
    def query(request)
      unary(:insights_query, request)
    end

    def segment_users(request)
      unary(:insights_segment_users, request)
    end

    def filter_schema(request = nil)
      unary(:insights_filter_schema, request)
    end

    def property_values(request)
      unary(:insights_property_values, request)
    end
  end
end
