# frozen_string_literal: true

require "test_helper"

module Sdp
  # Contract guard: every covered endpoint must exist in the vendored
  # pinned spec (spec/openapi-v0.31.json) with the expected verb, and every
  # field our structs read must be present in the success-response schema.
  # When SDP's spec moves, re-vendor and these tests name exactly what broke.
  class ContractTest < Minitest::Test
    SPEC_PATH = File.expand_path("../../spec/openapi-v0.31.json", __dir__)
    SPEC = JSON.parse(File.read(SPEC_PATH)).freeze

    Sdp::Coverage::COVERED_ENDPOINTS.each do |endpoint|
      label = "#{endpoint.method.upcase} #{endpoint.path}"

      define_method("test_contract_#{endpoint.method}_#{endpoint.path.gsub(/[^a-zA-Z0-9]+/, '_')}") do
        operation = SPEC.dig("paths", endpoint.path, endpoint.method)
        refute_nil operation, "#{label} is missing from the vendored spec"

        schema = Sdp::Coverage.success_schema(SPEC, endpoint)
        refute_nil schema,
          "#{label}: no application/json schema for success response #{endpoint.success_status}"

        endpoint.reads.each do |segments, fields|
          at = segments.empty? ? "response root" : "response #{segments.join('.')}"
          node = Sdp::Coverage.walk(SPEC, schema, segments)
          refute_nil node, "#{label}: #{at} not found in the pinned schema"

          properties = node["properties"] || {}
          fields.each do |field|
            assert properties.key?(field),
              "#{label}: field #{field} (read by this gem) is not in the schema properties at #{at}"
          end
        end
      end
    end

    def test_every_covered_endpoint_path_uses_the_specs_template_style
      Sdp::Coverage::COVERED_ENDPOINTS.each do |endpoint|
        refute_match(/:\w+/, endpoint.path,
          "covered paths must use the spec's {param} template style, not :param")
      end
    end

    def test_coverage_map_lists_the_covered_operations
      operations = Sdp::Coverage::COVERED_ENDPOINTS.map { |e| [ e.method, e.path ] }
      assert_equal 23, operations.size # 8 wallets/payments + 9 issuance + 6 ramps (v0.2)
      assert_equal operations.uniq, operations
    end
  end
end
