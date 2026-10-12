# frozen_string_literal: true

require "google/protobuf"
require "google/protobuf/well_known_types"
require_relative "gen/buf/validate/validate_pb"
require_relative "gen/common/v1/property_value_pb"
require_relative "gen/sdk/events/v1/events_pb"
require_relative "gen/sdk/profiles/v1/profiles_pb"
require_relative "gen/shared/activity/v1/activity_pb"
require_relative "gen/shared/insights/v1/insights_pb"
require_relative "gen/shared/profiles/v1/profiles_pb"
Dir.glob("gen/common/events/v1/*_pb.rb", base: __dir__).sort.each { |path| require_relative path }

module Pug
  module Proto
    # Custom options (the event catalog's kind and platforms, buf.validate's rules) are
    # extensions, read off a descriptor's options through the extension's FieldDescriptor.
    def self.extension(name)
      ::Google::Protobuf::DescriptorPool.generated_pool.lookup(name)
    end
  end
end
