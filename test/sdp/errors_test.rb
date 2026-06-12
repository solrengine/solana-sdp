# frozen_string_literal: true

require "test_helper"

module Sdp
  class ErrorsTest < Minitest::Test
    ALL_ERRORS = [
      Sdp::ConfigurationError,
      Sdp::BadRequest,
      Sdp::Unauthorized,
      Sdp::Forbidden,
      Sdp::InsufficientPermissions,
      Sdp::NotFound,
      Sdp::Conflict,
      Sdp::SigningPending,
      Sdp::TransactionFailed,
      Sdp::RateLimited,
      Sdp::Timeout,
      Sdp::Unavailable
    ].freeze

    def test_every_error_is_rescuable_as_sdp_error
      ALL_ERRORS.each do |klass|
        assert_operator klass, :<, Sdp::Error, "#{klass} must subclass Sdp::Error"
        assert_operator klass, :<, StandardError
      end
    end

    def test_insufficient_permissions_is_a_forbidden
      assert_operator Sdp::InsufficientPermissions, :<, Sdp::Forbidden
    end

    def test_carries_code_http_status_details_and_meta
      error = Sdp::Error.new(
        "boom",
        code: "SIGNING_PENDING",
        http_status: 202,
        details: { approvals_required: 2 },
        meta: { request_id: "req-1" }
      )

      assert_equal "boom", error.message
      assert_equal "SIGNING_PENDING", error.code
      assert_equal 202, error.http_status
      assert_equal({ approvals_required: 2 }, error.details)
      assert_equal({ request_id: "req-1" }, error.meta)
    end

    def test_attributes_default_to_nil
      error = Sdp::Error.new("plain")

      assert_nil error.code
      assert_nil error.http_status
      assert_nil error.details
      assert_nil error.meta
    end

    def test_rescue_sdp_error_catches_subclasses
      raise Sdp::SigningPending.new("pending", http_status: 202)
    rescue Sdp::Error => e
      assert_instance_of Sdp::SigningPending, e
      assert_equal 202, e.http_status
    end
  end
end
