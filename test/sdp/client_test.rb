# frozen_string_literal: true

require "test_helper"

module Sdp
  class ClientTest < Minitest::Test
    BASE_URL = "http://sdp.test:8787"
    WALLETS_URL = "#{BASE_URL}/v1/wallets".freeze
    TRANSFERS_URL = "#{BASE_URL}/v1/payments/transfers".freeze

    def setup
      @client = Sdp::Client.new(base_url: BASE_URL, api_key: "test-key")
    end

    # -- construction guard ---------------------------------------------------

    def test_nil_api_key_raises_configuration_error_at_construction
      with_env("SDP_API_KEY" => nil) do
        error = assert_raises(Sdp::ConfigurationError) do
          Sdp::Client.new(base_url: BASE_URL, api_key: nil)
        end
        assert_match(/SDP_API_KEY/, error.message)
      end
    end

    def test_blank_api_key_raises_configuration_error_at_construction
      with_env("SDP_API_KEY" => nil) do
        assert_raises(Sdp::ConfigurationError) do
          Sdp::Client.new(base_url: BASE_URL, api_key: "   ")
        end
      end
    end

    def test_api_key_and_base_url_fall_back_to_env
      with_env("SDP_API_KEY" => "env-key", "SDP_API_BASE_URL" => "http://env.test:9999") do
        client = Sdp::Client.new

        stub = stub_request(:get, "http://env.test:9999/v1/wallets")
          .with(headers: { "Authorization" => "Bearer env-key" })
          .to_return(status: 200, headers: json_headers, body: { data: [], meta: {} }.to_json)

        client.get("/v1/wallets")
        assert_requested(stub)
      end
    end

    # -- happy path: envelope handling ----------------------------------------

    def test_get_unwraps_data_and_symbolizes_camel_case_recursively
      stub_request(:get, WALLETS_URL)
        .to_return(
          status: 200,
          headers: json_headers,
          body: {
            data: {
              walletBalances: {
                walletId: "wal_123",
                balances: [
                  { token: "SOL", uiAmount: "1.5", usdValue: "225.38", decimals: 9 }
                ]
              }
            },
            meta: { requestId: "req-1", hasMore: false }
          }.to_json
        )

      response = @client.get("/v1/wallets")

      balances = response.data[:wallet_balances]
      assert_equal "wal_123", balances[:wallet_id]
      assert_equal "1.5", balances[:balances].first[:ui_amount]
      assert_equal "225.38", balances[:balances].first[:usd_value]
      assert_equal 9, balances[:balances].first[:decimals]
    end

    def test_meta_is_accessible_alongside_data
      stub_request(:get, TRANSFERS_URL)
        .to_return(
          status: 200,
          headers: json_headers,
          body: { data: [ { id: "tr_1" } ], meta: { total: 41, page: 1, pageSize: 20, hasMore: true } }.to_json
        )

      response = @client.get("/v1/payments/transfers")

      assert_equal [ { id: "tr_1" } ], response.data
      assert_equal 41, response.meta[:total]
      assert_equal true, response.meta[:has_more]
      assert_equal 20, response.meta[:page_size]
    end

    def test_sends_bearer_and_accept_headers
      stub = stub_request(:get, WALLETS_URL)
        .with(headers: { "Authorization" => "Bearer test-key", "Accept" => "application/json" })
        .to_return(status: 200, headers: json_headers, body: { data: [], meta: {} }.to_json)

      @client.get("/v1/wallets")
      assert_requested(stub)
    end

    def test_post_sends_json_body_and_bearer_header
      stub = stub_request(:post, WALLETS_URL)
        .with(
          headers: { "Authorization" => "Bearer test-key", "Content-Type" => "application/json" },
          body: { label: "treasury" }.to_json
        )
        .to_return(status: 201, headers: json_headers,
                   body: { data: { wallet: { walletId: "wal_t" } }, meta: {} }.to_json)

      response = @client.post("/v1/wallets", { label: "treasury" })

      assert_requested(stub)
      assert_equal "wal_t", response.data[:wallet][:wallet_id]
    end

    def test_204_empty_body_is_handled
      stub_request(:get, WALLETS_URL).to_return(status: 204, body: "")

      response = @client.get("/v1/wallets")

      assert_nil response.data
      assert_nil response.meta
    end

    # -- the 202 trap ----------------------------------------------------------

    def test_202_signing_pending_raises_instead_of_parsing_as_success
      stub_request(:post, TRANSFERS_URL)
        .to_return(
          status: 202,
          headers: json_headers,
          body: {
            error: {
              code: "SIGNING_PENDING",
              message: "Transaction accepted, awaiting signatures",
              details: { approvalsReceived: 1, approvalsRequired: 2 }
            },
            meta: { requestId: "req-202" }
          }.to_json
        )

      error = assert_raises(Sdp::SigningPending) do
        @client.post("/v1/payments/transfers", { source: "a", destination: "b", amount: "1" })
      end

      assert_equal "Transaction accepted, awaiting signatures", error.message
      assert_equal "SIGNING_PENDING", error.code
      assert_equal 202, error.http_status
      assert_equal({ approvals_received: 1, approvals_required: 2 }, error.details)
    end

    def test_202_without_code_still_raises_signing_pending_by_status
      stub_request(:post, TRANSFERS_URL).to_return(status: 202, headers: json_headers, body: "{}")

      error = assert_raises(Sdp::SigningPending) do
        @client.post("/v1/payments/transfers", { source: "a", destination: "b", amount: "1" })
      end
      assert_equal 202, error.http_status
    end

    # -- error mapping ---------------------------------------------------------

    def test_401_invalid_api_key_raises_unauthorized_with_code_preserved
      stub_request(:get, WALLETS_URL)
        .to_return(status: 401, headers: json_headers, body: error_body("INVALID_API_KEY", "Invalid API key"))

      error = assert_raises(Sdp::Unauthorized) { @client.get("/v1/wallets") }
      assert_equal "Invalid API key", error.message
      assert_equal "INVALID_API_KEY", error.code
      assert_equal 401, error.http_status
    end

    def test_403_with_insufficient_permissions_code_takes_precedence_over_status
      stub_request(:post, WALLETS_URL)
        .to_return(status: 403, headers: json_headers,
                   body: error_body("INSUFFICIENT_PERMISSIONS", "Key lacks custody:admin scope"))

      error = assert_raises(Sdp::InsufficientPermissions) { @client.post("/v1/wallets", {}) }
      assert_equal "Key lacks custody:admin scope", error.message
    end

    def test_plain_403_raises_forbidden_not_insufficient_permissions
      stub_request(:get, WALLETS_URL).to_return(status: 403, body: "Forbidden")

      error = assert_raises(Sdp::Forbidden) { @client.get("/v1/wallets") }
      refute_instance_of Sdp::InsufficientPermissions, error
      assert_equal 403, error.http_status
    end

    def test_404_message_appends_the_wallet_scope_hint
      stub_request(:get, "#{BASE_URL}/v1/payments/wallets/wal_x/balances")
        .to_return(status: 404, headers: json_headers, body: error_body("NOT_FOUND", "Wallet not found"))

      error = assert_raises(Sdp::NotFound) { @client.get("/v1/payments/wallets/wal_x/balances") }
      assert_match(/\AWallet not found/, error.message)
      assert_match(/wallet-scoped API keys return 404/, error.message)
    end

    # 409 on /v1/wallets/initialize specifically raises ProviderCapabilityError
    # (FL-10, see capability_errors_test.rb); these cover the generic mapping.
    def test_409_conflict_code_raises_conflict
      stub_request(:post, WALLETS_URL)
        .to_return(status: 409, headers: json_headers,
                   body: error_body("CONFLICT", "Wallet already exists"))

      error = assert_raises(Sdp::Conflict) { @client.post("/v1/wallets") }
      assert_equal "Wallet already exists", error.message
      assert_equal "CONFLICT", error.code
    end

    def test_plain_409_raises_conflict_by_status
      stub_request(:post, WALLETS_URL).to_return(status: 409, body: "")

      error = assert_raises(Sdp::Conflict) { @client.post("/v1/wallets") }
      assert_equal 409, error.http_status
    end

    def test_transaction_failed_code_on_500_takes_precedence_over_unavailable
      stub_request(:post, TRANSFERS_URL)
        .to_return(status: 500, headers: json_headers, body: error_body("TRANSACTION_FAILED", "send failed"))

      error = assert_raises(Sdp::TransactionFailed) do
        @client.post("/v1/payments/transfers", { amount: "1" })
      end
      assert_equal "send failed", error.message
    end

    def test_5xx_with_html_body_raises_unavailable
      stub = stub_request(:post, TRANSFERS_URL)
        .to_return(status: 500, body: "<html>Internal Server Error</html>")

      error = assert_raises(Sdp::Unavailable) do
        @client.post("/v1/payments/transfers", { amount: "1" })
      end
      assert_equal 500, error.http_status
      assert_requested(stub, times: 1)
    end

    def test_connection_refused_raises_unavailable
      stub_request(:post, WALLETS_URL).to_raise(Errno::ECONNREFUSED)

      assert_raises(Sdp::Unavailable) { @client.post("/v1/wallets", {}) }
    end

    # -- retry policy ----------------------------------------------------------

    def test_get_retries_once_on_read_timeout_then_succeeds
      stub = stub_request(:get, WALLETS_URL)
        .to_raise(Net::ReadTimeout)
        .then
        .to_return(status: 200, headers: json_headers,
                   body: { data: { wallets: [ { walletId: "wal_1" } ] }, meta: {} }.to_json)

      response = @client.get("/v1/wallets")

      assert_equal "wal_1", response.data[:wallets].first[:wallet_id]
      assert_requested(stub, times: 2)
    end

    def test_get_fails_after_the_second_read_timeout
      stub = stub_request(:get, WALLETS_URL).to_raise(Net::ReadTimeout)

      assert_raises(Sdp::Timeout) { @client.get("/v1/wallets") }
      assert_requested(stub, times: 2)
    end

    def test_get_connect_timeout_maps_to_unavailable_and_retries_once
      stub = stub_request(:get, WALLETS_URL).to_timeout

      assert_raises(Sdp::Unavailable) { @client.get("/v1/wallets") }
      assert_requested(stub, times: 2)
    end

    def test_get_retries_once_on_unavailable_5xx_then_raises
      stub = stub_request(:get, WALLETS_URL).to_return(status: 502, body: "Bad Gateway")

      assert_raises(Sdp::Unavailable) { @client.get("/v1/wallets") }
      assert_requested(stub, times: 2)
    end

    def test_post_never_retries_on_read_timeout
      stub = stub_request(:post, TRANSFERS_URL).to_raise(Net::ReadTimeout)

      assert_raises(Sdp::Timeout) { @client.post("/v1/payments/transfers", { amount: "1" }) }
      assert_requested(stub, times: 1)
    end

    def test_post_never_retries_on_connect_timeout
      stub = stub_request(:post, TRANSFERS_URL).to_timeout

      assert_raises(Sdp::Unavailable) { @client.post("/v1/payments/transfers", { amount: "1" }) }
      assert_requested(stub, times: 1)
    end

    private

    def json_headers
      { "Content-Type" => "application/json" }
    end

    def error_body(code, message)
      { error: { code: code, message: message }, meta: { requestId: "req-err" } }.to_json
    end

    def with_env(pairs)
      originals = pairs.keys.to_h { |key| [ key, ENV[key] ] }
      pairs.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
      yield
    ensure
      originals.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    end
  end
end
