# frozen_string_literal: true

require_relative "connect"
require_relative "proto"

module Pug
  class RPC
    EventsV1 = Proto::Sdk::Events::V1
    SdkProfilesV1 = Proto::Sdk::Profiles::V1
    ProfilesV1 = Proto::Shared::Profiles::V1
    ActivityV1 = Proto::Shared::Activity::V1
    InsightsV1 = Proto::Shared::Insights::V1
    CommonV1 = Proto::Common::V1

    PROCEDURES = {
      batch_create: ["sdk.events.v1.EventsService/BatchCreate", EventsV1::BatchCreateRequest,
                     EventsV1::BatchCreateResponse],
      identify: ["sdk.profiles.v1.ProfilesSDKService/Identify", SdkProfilesV1::IdentifyRequest,
                 SdkProfilesV1::IdentifyResponse],
      profiles_get: ["shared.profiles.v1.ProfilesService/Get", ProfilesV1::GetRequest, ProfilesV1::GetResponse],
      profiles_get_by_external_id: ["shared.profiles.v1.ProfilesService/GetByExternalId",
                                    ProfilesV1::GetByExternalIdRequest, ProfilesV1::GetByExternalIdResponse],
      profiles_delete: ["shared.profiles.v1.ProfilesService/Delete", ProfilesV1::DeleteRequest,
                        ProfilesV1::DeleteResponse],
      profiles_list: ["shared.profiles.v1.ProfilesService/List", ProfilesV1::ListRequest, ProfilesV1::ListResponse],
      activity_feed: ["shared.activity.v1.ActivityService/GetActivityFeed", ActivityV1::GetActivityFeedRequest,
                      ActivityV1::GetActivityFeedResponse],
      activity_event_explorer: ["shared.activity.v1.ActivityService/GetEventExplorer",
                                ActivityV1::GetEventExplorerRequest, ActivityV1::GetEventExplorerResponse],
      activity_heatmap: ["shared.activity.v1.ActivityService/GetActivityHeatmap", ActivityV1::GetActivityHeatmapRequest,
                         ActivityV1::GetActivityHeatmapResponse],
      activity_profile_sessions: ["shared.activity.v1.ActivityService/GetProfileSessions",
                                  ActivityV1::GetProfileSessionsRequest, ActivityV1::GetProfileSessionsResponse],
      activity_profile_stats: ["shared.activity.v1.ActivityService/GetProfileStats", ActivityV1::GetProfileStatsRequest,
                               ActivityV1::GetProfileStatsResponse],
      activity_filter_schema: ["shared.activity.v1.ActivityService/GetFilterSchema", CommonV1::GetFilterSchemaRequest,
                               CommonV1::GetFilterSchemaResponse],
      activity_property_values: ["shared.activity.v1.ActivityService/GetPropertyValues",
                                 ActivityV1::GetPropertyValuesRequest, ActivityV1::GetPropertyValuesResponse],
      insights_query: ["shared.insights.v1.InsightsService/Query", InsightsV1::QueryRequest, InsightsV1::QueryResponse],
      insights_segment_users: ["shared.insights.v1.InsightsService/SegmentUsers", InsightsV1::SegmentUsersRequest,
                               InsightsV1::SegmentUsersResponse],
      insights_filter_schema: ["shared.insights.v1.InsightsService/GetFilterSchema", CommonV1::GetFilterSchemaRequest,
                               CommonV1::GetFilterSchemaResponse],
      insights_property_values: ["shared.insights.v1.InsightsService/GetPropertyValues",
                                 InsightsV1::GetPropertyValuesRequest, InsightsV1::GetPropertyValuesResponse]
    }.freeze

    def self.request(name, request)
      klass = PROCEDURES.fetch(name)[1]
      case request
      when nil then klass.new
      when klass then request
      when Hash then klass.new(request)
      else raise ArgumentError, "expected a Hash or #{klass}, got #{request.class}"
      end
    end

    def initialize(connect)
      @connect = connect
    end

    def unary(name, request)
      path, _, response = PROCEDURES.fetch(name)
      @connect.unary(path, self.class.request(name, request), response)
    end

    def stream(name, request, timeout: nil, &)
      path, _, response = PROCEDURES.fetch(name)
      @connect.server_stream(path, self.class.request(name, request), response, timeout: timeout, &)
    end
  end
end
