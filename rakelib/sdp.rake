# frozen_string_literal: true

require_relative "../lib/sdp/drift"

namespace :sdp do
  desc "Diff a newer SDP OpenAPI spec against the vendored v0.31 pin " \
       "(covered endpoints only; a diff is a report, never a failure — always exits 0)"
  task :drift, [ :newer_spec ] do |_t, args|
    pinned = File.expand_path("../spec/openapi-v0.31.json", __dir__)
    Sdp::Drift.run(pinned_path: pinned, newer_path: args[:newer_spec].to_s)
  end
end
