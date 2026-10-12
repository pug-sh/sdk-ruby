# frozen_string_literal: true

# protoc's Ruby generator requires each import by its proto path ('common/v1/property_value_pb'),
# which only resolves with the output directory on $LOAD_PATH. The gem keeps its generated code
# under lib/pug/gen instead, so imports generated alongside become require_relative; the
# google/protobuf ones still come from the google-protobuf gem.

require "pathname"

root = Pathname(ARGV.fetch(0)).expand_path
root.glob("**/*_pb.rb").each do |file|
  source = file.read
  rewritten = source.gsub(/^require '([^']+_pb)'$/) do |line|
    target = root.join("#{Regexp.last_match(1)}.rb")
    next line unless target.exist?

    "require_relative '#{target.relative_path_from(file.dirname).sub_ext("")}'"
  end
  file.write(rewritten) unless rewritten == source
end
