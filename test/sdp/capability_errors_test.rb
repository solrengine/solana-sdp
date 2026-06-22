# frozen_string_literal: true

require "test_helper"

module Sdp
  # FL-10/FL-11 capability gates. Upstream messages in these stubs are the
  # exact strings SDP v0.31 sends (verified against the SDP source — see the
  # pattern constants in lib/sdp/errors.rb).
  class CapabilityErrorsTest < Minitest::Test
    BASE_URL = "http://sdp.test:8787"

    def setup
      @client = Sdp::Client.new(base_url: BASE_URL, api_key: "test-key")
    end

    # -- FL-10: wallet provisioning gate (400) --------------------------------

    def test_provisioning_gate_400_raises_provider_capability_error_naming_the_fix
      stub_request(:post, "#{BASE_URL}/v1/wallets")
        .to_return(
          status: 400,
          headers: json_headers,
          body: error_body("INVALID_REQUEST", "Wallet provisioning not supported for provider: local")
        )

      error = assert_raises(Sdp::ProviderCapabilityError) do
        @client.create_wallet(label: "user-42")
      end

      # Upstream evidence preserved, limitation and fix both named.
      assert_match(/Wallet provisioning not supported for provider: local/, error.message)
      assert_match(/local custody holds a single root wallet/, error.message)
      assert_match(/managed provider \(e\.g\. privy\)/, error.message)
      assert_match(/SDP_CUSTODY_PROVIDER/, error.message)
      assert_equal 400, error.http_status
    end

    def test_plain_validation_400_stays_bad_request
      stub_request(:post, "#{BASE_URL}/v1/wallets")
        .to_return(
          status: 400,
          headers: json_headers,
          body: error_body("VALIDATION_ERROR", "label is required")
        )

      error = assert_raises(Sdp::BadRequest) { @client.create_wallet(label: "") }

      assert_instance_of Sdp::BadRequest, error,
        "a plain validation 400 must not be promoted to ProviderCapabilityError"
      assert_equal "label is required", error.message
    end

    # -- FL-10: second initialize (409) ----------------------------------------

    def test_409_on_initialize_raises_provider_capability_error_with_initialize_message
      stub_request(:post, "#{BASE_URL}/v1/wallets/initialize")
        .to_return(
          status: 409,
          headers: json_headers,
          body: error_body("CONFLICT", "Custody already initialized for this project")
        )

      error = assert_raises(Sdp::ProviderCapabilityError) { @client.initialize_custody }

      assert_match(/already initialized/, error.message)
      assert_match(/initialize_custody is one-time/, error.message)
      assert_equal 409, error.http_status
    end

    def test_409_off_the_initialize_path_stays_conflict
      stub_request(:post, "#{BASE_URL}/v1/wallets")
        .to_return(
          status: 409,
          headers: json_headers,
          body: error_body("CONFLICT", "Wallet with this label already exists")
        )

      error = assert_raises(Sdp::Conflict) { @client.create_wallet(label: "dup") }
      assert_instance_of Sdp::Conflict, error
    end

    # -- FL-11: native fee adapter cannot submit (502) -------------------------

    def test_502_with_native_adapter_signature_raises_transfer_execution_error_naming_kora
      stub_request(:post, "#{BASE_URL}/v1/payments/transfers")
        .to_return(
          status: 502,
          headers: json_headers,
          body: error_body(
            "SOLANA_RPC_ERROR",
            "NativeAdapter.signAndSend not supported - use KoraAdapter for gasless transactions"
          )
        )

      error = assert_raises(Sdp::TransferExecutionError) do
        @client.create_transfer(source: "wal_1", destination: "Dest111", amount: "0.1")
      end

      assert_match(/NativeAdapter\.signAndSend not supported/, error.message)
      assert_match(/run Kora and set FEE_PAYMENT_PROVIDER=kora/, error.message)
      assert_equal "SOLANA_RPC_ERROR", error.code
      assert_equal 502, error.http_status
    end

    def test_502_solana_rpc_error_without_native_signature_stays_unavailable_with_no_kora_claim
      stub_request(:post, "#{BASE_URL}/v1/payments/transfers")
        .to_return(
          status: 502,
          headers: json_headers,
          body: error_body("SOLANA_RPC_ERROR", "RPC node unreachable")
        )

      error = assert_raises(Sdp::Unavailable) do
        @client.create_transfer(source: "wal_1", destination: "Dest111", amount: "0.1")
      end

      assert_match(/RPC node unreachable/, error.message)
      refute_match(/kora/i, error.message,
        "a real RPC outage must never be mislabeled as a Kora configuration problem")
    end

    # -- rescue semantics -------------------------------------------------------

    def test_provider_capability_error_is_rescuable_as_bad_request_and_sdp_error
      assert_operator Sdp::ProviderCapabilityError, :<, Sdp::BadRequest
      assert_operator Sdp::ProviderCapabilityError, :<, Sdp::Error
    end

    def test_transfer_execution_error_is_rescuable_as_sdp_error_but_not_unavailable
      assert_operator Sdp::TransferExecutionError, :<, Sdp::Error
      refute_operator Sdp::TransferExecutionError, :<, Sdp::Unavailable
    end

    private

    def error_body(code, message)
      { error: { code: code, message: message }, meta: { requestId: "req-test" } }.to_json
    end

    def json_headers
      { "Content-Type" => "application/json" }
    end
  end
end
