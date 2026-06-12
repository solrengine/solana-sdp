# frozen_string_literal: true

require "test_helper"
require "stringio"
require "tempfile"
require "sdp/drift"

module Sdp
  # The drift diff is exercised against doctored "v0.29" specs derived from
  # the real vendored pin, so path/schema navigation is tested on the real
  # spec structure, not on toy fixtures.
  class DriftTest < Minitest::Test
    PINNED_PATH = File.expand_path("../../spec/openapi-v0.28.json", __dir__)
    PINNED_RAW = File.read(PINNED_PATH).freeze
    PINNED = JSON.parse(PINNED_RAW).freeze

    BALANCES_PATH = "/v1/payments/wallets/{walletId}/balances"
    RAMPS_PATH = "/v1/payments/ramps/onramp/quote" # uncovered surface

    def test_identical_specs_report_no_drift
      assert_empty Drift.diff(PINNED, doctored)
    end

    # The known real-world case: balances response gains usdValue as
    # guaranteed-present in "v0.29" — the diff must name the balances endpoint.
    def test_balances_field_becoming_required_is_reported
      newer = doctored do |spec|
        items = balance_items(spec)
        items["required"] = (items["required"] || []) + [ "usdValue" ]
      end

      findings = Drift.diff(PINNED, newer)
      finding = findings.find { |f| f.include?(BALANCES_PATH) }

      refute_nil finding, "expected a finding naming the balances endpoint, got: #{findings.inspect}"
      assert_match(/became required: usdValue/, finding)
    end

    def test_removed_response_field_on_covered_endpoint_is_reported
      newer = doctored do |spec|
        balance_items(spec)["properties"].delete("usdValue")
      end

      findings = Drift.diff(PINNED, newer)
      assert(findings.any? { |f| f.include?(BALANCES_PATH) && f =~ /removed\/renamed field\(s\): usdValue/ },
        "expected usdValue removal reported on balances, got: #{findings.inspect}")
    end

    def test_covered_endpoint_missing_from_newer_spec_is_reported
      newer = doctored { |spec| spec["paths"].delete("/v1/payments/transfers/prepare") }

      findings = Drift.diff(PINNED, newer)
      assert_includes findings, "POST /v1/payments/transfers/prepare: endpoint missing from newer spec"
    end

    def test_added_required_request_param_is_reported
      newer = doctored do |spec|
        body = spec.dig("paths", "/v1/payments/transfers", "post",
                        "requestBody", "content", "application/json", "schema")
        body["required"] = body["required"] + [ "projectId" ]
      end

      findings = Drift.diff(PINNED, newer)
      assert(findings.any? { |f| f.include?("POST /v1/payments/transfers") && f.include?("required param(s): projectId") },
        "expected projectId reported as newly required, got: #{findings.inspect}")
    end

    # Churn outside the covered surface (ramps, issuance, ...) is invisible.
    def test_changes_to_uncovered_endpoints_are_silent
      newer = doctored do |spec|
        assert spec["paths"].key?(RAMPS_PATH), "fixture assumption: ramps path present in pinned spec"
        spec["paths"].delete(RAMPS_PATH)
        spec["paths"]["/v1/payments/ramps/brand-new"] = { "post" => { "responses" => {} } }
      end

      assert_empty Drift.diff(PINNED, newer)
    end

    # -- Drift.run (the rake-task surface) -------------------------------------

    def test_unreadable_newer_spec_reports_unavailable_and_never_claims_no_drift
      out = StringIO.new
      result = Drift.run(pinned_path: PINNED_PATH, newer_path: "/nonexistent/openapi.json", out: out)

      assert_nil result
      assert_match(/drift check unavailable/, out.string)
      refute_match(/no drift/i, out.string)
    end

    def test_run_prints_findings_for_a_drifted_spec
      newer = doctored { |spec| spec["paths"].delete("/v1/wallets/initialize") }

      Tempfile.create([ "openapi-newer", ".json" ]) do |file|
        file.write(JSON.generate(newer))
        file.flush

        out = StringIO.new
        findings = Drift.run(pinned_path: PINNED_PATH, newer_path: file.path, out: out)

        refute_empty findings
        assert_match(/Drift detected on the covered surface/, out.string)
        assert_match(%r{POST /v1/wallets/initialize: endpoint missing}, out.string)
        refute_match(/no drift/i, out.string)
      end
    end

    def test_run_reports_no_drift_for_an_identical_spec
      out = StringIO.new
      findings = Drift.run(pinned_path: PINNED_PATH, newer_path: PINNED_PATH, out: out)

      assert_empty findings
      assert_match(/No drift on the covered surface/, out.string)
    end

    private

    # A fresh deep copy of the pinned spec, optionally doctored in place.
    def doctored
      copy = JSON.parse(PINNED_RAW)
      yield copy if block_given?
      copy
    end

    def balance_items(spec)
      spec.dig("paths", BALANCES_PATH, "get", "responses", "200", "content", "application/json",
               "schema", "properties", "data", "properties", "walletBalances",
               "properties", "balances", "items")
    end
  end
end
