# frozen_string_literal: true

require "json"
require_relative "coverage"

module Sdp
  # Diffs a newer SDP OpenAPI spec against the vendored pin, restricted to
  # the covered surface (Sdp::Coverage::COVERED_ENDPOINTS). Drives the
  # `rake "sdp:drift[path]"` task.
  #
  # A diff is a REPORT, not a build failure: SDP moving must never break this
  # gem's own CI, so #run always returns normally (the rake task exits 0).
  # The one hard rule: an unreadable spec prints "drift check unavailable"
  # and never a false "no drift" claim.
  module Drift
    module_function

    # Prints a drift report to `out`. Returns the findings array, or nil when
    # the check could not run at all.
    def run(pinned_path:, newer_path:, out: $stdout)
      newer = read_spec(newer_path)
      if newer.nil?
        out.puts "drift check unavailable: could not read newer spec at #{newer_path.inspect}"
        return nil
      end

      pinned = read_spec(pinned_path)
      if pinned.nil?
        out.puts "drift check unavailable: could not read pinned spec at #{pinned_path.inspect}"
        return nil
      end

      findings = diff(pinned, newer)
      if findings.empty?
        out.puts "No drift on the covered surface (#{Coverage::COVERED_ENDPOINTS.size} endpoints)."
      else
        out.puts "Drift detected on the covered surface (#{findings.size} finding(s) — report, not a failure):"
        findings.each { |finding| out.puts "  - #{finding}" }
      end
      findings
    end

    # Compares the two parsed specs over the covered endpoints only.
    # Returns human-readable finding strings; uncovered endpoints (ramps,
    # issuance, ...) never appear here no matter how much they change.
    def diff(pinned, newer)
      Coverage::COVERED_ENDPOINTS.flat_map do |endpoint|
        label = "#{endpoint.method.upcase} #{endpoint.path}"
        newer_operation = newer.dig("paths", endpoint.path, endpoint.method)
        next [ "#{label}: endpoint missing from newer spec" ] unless newer_operation

        response_findings(label, endpoint, pinned, newer) +
          request_findings(label, endpoint, pinned, newer)
      end
    end

    def read_spec(path)
      JSON.parse(File.read(path.to_s))
    rescue StandardError
      nil
    end

    # For every schema node the gem reads, reports fields that disappeared
    # (removed/renamed) and fields that became required (shape guarantees
    # changed — e.g. the v0.28→v0.29 usdValue change on balances).
    def response_findings(label, endpoint, pinned, newer)
      pinned_schema = Coverage.success_schema(pinned, endpoint)
      newer_schema = Coverage.success_schema(newer, endpoint)
      return [ "#{label}: success response #{endpoint.success_status} missing from newer spec" ] unless newer_schema
      return [] unless pinned_schema # nothing pinned to compare against

      endpoint.reads.flat_map do |segments, _fields|
        at = segments.empty? ? "response root" : "response #{segments.join('.')}"
        pinned_node = Coverage.walk(pinned, pinned_schema, segments)
        newer_node = Coverage.walk(newer, newer_schema, segments)
        next [] unless pinned_node
        next [ "#{label}: #{at} no longer present in newer spec" ] unless newer_node

        findings = []
        removed = properties(pinned_node) - properties(newer_node)
        findings << "#{label}: #{at} removed/renamed field(s): #{removed.join(', ')}" unless removed.empty?

        newly_required = required(newer_node) - required(pinned_node)
        unless newly_required.empty?
          findings << "#{label}: #{at} field(s) became required: #{newly_required.join(', ')}"
        end
        findings
      end
    end

    # Reports request-body params that became required in the newer spec —
    # existing gem calls would start failing with 400s.
    def request_findings(label, endpoint, pinned, newer)
      pinned_required = request_required(pinned, endpoint)
      newer_required = request_required(newer, endpoint)

      added = newer_required - pinned_required
      return [] if added.empty?

      [ "#{label}: request body added required param(s): #{added.join(', ')}" ]
    end

    def request_required(spec, endpoint)
      schema = spec.dig("paths", endpoint.path, endpoint.method,
                        "requestBody", "content", "application/json", "schema")
      required(Coverage.resolve(spec, schema))
    end

    def properties(node)
      props = node.is_a?(Hash) ? node["properties"] : nil
      props.is_a?(Hash) ? props.keys : []
    end

    def required(node)
      req = node.is_a?(Hash) ? node["required"] : nil
      req.is_a?(Array) ? req : []
    end
  end
end
