# frozen_string_literal: true

require_relative "proto"

module Pug
  # Like sdk-node's generated registry, the catalog holds the events whose
  # (common.events.v1.platforms) option lists PLATFORM_SERVER or is unset; one tagged only for
  # web, mobile or desktop is a custom event here.
  module WellKnown
    KIND = Proto.extension("common.events.v1.kind")
    PLATFORMS = Proto.extension("common.events.v1.platforms")

    def self.build
      namespace = Proto::Common::Events::V1
      classes = namespace.constants.map { |name| namespace.const_get(name) }
      classes = classes.select { |klass| klass.is_a?(Class) && klass.respond_to?(:descriptor) }
      classes.sort_by { |klass| klass.descriptor.name }.each_with_object({}) do |klass, catalog|
        options = klass.descriptor.options
        kind = KIND.get(options)
        next if kind.empty? || catalog.key?(kind)

        platforms = PLATFORMS.get(options)
        catalog[kind] = klass if platforms.empty? || platforms.include?(:PLATFORM_SERVER)
      end.freeze
    end

    CATALOG = build

    def self.[](kind)
      CATALOG[kind]
    end
  end
end
