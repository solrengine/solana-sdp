# frozen_string_literal: true

require "test_helper"

module Sdp
  class RampsTest < Minitest::Test
    BASE_URL = "http://sdp.test:8787"
    RAMPS = "#{BASE_URL}/v1/payments/ramps".freeze

    def setup
      @client = Sdp::Client.new(base_url: BASE_URL, api_key: "test-key")
    end

    # -- currency discovery -----------------------------------------------------

    def test_onramp_currencies_sends_filters_and_parses_nested_discovery
      stub = stub_request(:get, "#{RAMPS}/onramp/currency")
        .with(query: { "source" => "USD", "dest" => "SOL", "provider" => "bvnk" })
        .to_return(status: 200, headers: json_headers,
                   body: { data: { currencies: { sources: %w[USD EUR], destinations: %w[SOL USDC] },
                                   pairs: [ { source: "USD", dest: "SOL", providers: %w[bvnk] } ],
                                   supportHash: "h123" },
                           meta: {} }.to_json)

      currencies = @client.onramp_currencies(source: "USD", dest: "SOL", provider: "bvnk")

      assert_requested(stub)
      assert_instance_of Sdp::RampCurrencies, currencies
      assert_equal %w[USD EUR], currencies.sources
      assert_equal %w[SOL USDC], currencies.destinations
      assert_equal "h123", currencies.support_hash
      assert_equal [ { source: "USD", dest: "SOL", providers: %w[bvnk] } ], currencies.pairs
    end

    def test_offramp_currencies_hits_the_offramp_path
      stub = stub_request(:get, "#{RAMPS}/offramp/currency")
        .to_return(status: 200, headers: json_headers,
                   body: { data: { currencies: { sources: %w[SOL], destinations: %w[USD] }, pairs: [] },
                           meta: {} }.to_json)

      currencies = @client.offramp_currencies

      assert_requested(stub)
      assert_equal %w[SOL], currencies.sources
      assert_equal [], currencies.pairs
    end

    def test_currencies_empty_body_degrades_to_empty_arrays
      stub_request(:get, "#{RAMPS}/onramp/currency").to_return(status: 200, body: "")

      currencies = @client.onramp_currencies

      assert_instance_of Sdp::RampCurrencies, currencies
      assert_equal [], currencies.sources
      assert_equal [], currencies.destinations
      assert_nil currencies.support_hash
    end

    # -- onramp_quote -----------------------------------------------------------

    def test_onramp_quote_posts_camelcased_payload_and_returns_quote
      stub = stub_request(:post, "#{RAMPS}/onramp/quote")
        .with(body: { provider: "bvnk", counterpartyId: "cp_1", destinationWallet: "wal_a",
                      cryptoToken: "SOL", fiatCurrency: "USD", fiatAmount: "100" })
        .to_return(status: 200, headers: json_headers,
                   body: { data: { quote: {
                     id: "q_1", provider: "bvnk", status: "quoted", deliveryMode: "hosted",
                     hostedUrl: "https://pay.example/q_1", exchangeRate: 150.2,
                     totalSendingAmount: 100, sendingCurrency: { code: "USD", decimals: 2 },
                     totalReceivingAmount: 0.66, receivingCurrency: { code: "SOL", decimals: 9 },
                     feesIncluded: 1.5, feeCurrency: { code: "USD" }, expiresAt: "2026-06-22T11:00:00Z"
                   } }, meta: {} }.to_json)

      quote = @client.onramp_quote(provider: "bvnk", counterparty_id: "cp_1", destination_wallet: "wal_a",
                                   crypto_token: "SOL", fiat_currency: "USD", fiat_amount: 100)

      assert_requested(stub)
      assert_instance_of Sdp::RampQuote, quote
      assert_equal "q_1", quote.id
      assert_equal "hosted", quote.delivery_mode
      assert_equal "https://pay.example/q_1", quote.hosted_url
      assert_equal 150.2, quote.exchange_rate
      assert_equal({ code: "USD", decimals: 2 }, quote.sending_currency) # passthrough
      assert_equal "2026-06-22T11:00:00Z", quote.expires_at
    end

    def test_onramp_quote_sends_optional_redirect_and_collected_data
      stub = stub_request(:post, "#{RAMPS}/onramp/quote")
        .with(body: { provider: "bvnk", counterpartyId: "cp_1", destinationWallet: "wal_a",
                      cryptoToken: "SOL", fiatCurrency: "USD", fiatAmount: "50",
                      redirectUrl: "https://app/return", collectedData: { kycTier: 1 } })
        .to_return(status: 200, headers: json_headers, body: { data: { quote: { id: "q_2" } }, meta: {} }.to_json)

      @client.onramp_quote(provider: "bvnk", counterparty_id: "cp_1", destination_wallet: "wal_a",
                           crypto_token: "SOL", fiat_currency: "USD", fiat_amount: "50",
                           redirect_url: "https://app/return", collected_data: { kycTier: 1 })
      assert_requested(stub)
    end

    # -- execute ----------------------------------------------------------------

    def test_onramp_execute_posts_compliance_passthrough_and_returns_ramp
      compliance = { ruleEntity: { type: "INDIVIDUAL", firstName: "Ada" } }
      stub = stub_request(:post, "#{RAMPS}/onramp/execute")
        .with(body: { provider: "bvnk", counterpartyId: "cp_1", destinationWallet: "wal_a",
                      cryptoToken: "SOL", fiatCurrency: "USD", fiatAmount: "100",
                      kycReference: "kyc_9", bvnkCompliance: compliance })
        .to_return(status: 200, headers: json_headers,
                   body: { data: { ramp: { id: "rmp_1", provider: "bvnk", status: "pending",
                                           redirectUrl: "https://pay.example/rmp_1", reference: "ref_1" } },
                           meta: {} }.to_json)

      ramp = @client.onramp_execute(provider: "bvnk", counterparty_id: "cp_1", destination_wallet: "wal_a",
                                    crypto_token: "SOL", fiat_currency: "USD", fiat_amount: 100,
                                    kyc_reference: "kyc_9", compliance: compliance)

      assert_requested(stub)
      assert_instance_of Sdp::RampExecution, ramp
      assert_equal "rmp_1", ramp.id
      assert_equal "pending", ramp.status
      assert_equal "https://pay.example/rmp_1", ramp.redirect_url
      assert_equal "ref_1", ramp.reference
    end

    def test_offramp_execute_uses_source_wallet_and_crypto_amount
      stub = stub_request(:post, "#{RAMPS}/offramp/execute")
        .with(body: { provider: "bvnk", counterpartyId: "cp_1", sourceWallet: "wal_a",
                      cryptoToken: "SOL", fiatCurrency: "USD", cryptoAmount: "0.5" })
        .to_return(status: 200, headers: json_headers,
                   body: { data: { ramp: { id: "rmp_2", status: "pending" } }, meta: {} }.to_json)

      ramp = @client.offramp_execute(provider: "bvnk", counterparty_id: "cp_1", source_wallet: "wal_a",
                                     crypto_token: "SOL", fiat_currency: "USD", crypto_amount: 0.5)

      assert_requested(stub)
      assert_equal "rmp_2", ramp.id
    end

    def test_execute_empty_body_degrades_to_all_nil_ramp
      stub_request(:post, "#{RAMPS}/onramp/execute").to_return(status: 200, body: "")

      ramp = @client.onramp_execute(provider: "bvnk", counterparty_id: "cp_1", destination_wallet: "wal_a",
                                    crypto_token: "SOL", fiat_currency: "USD", fiat_amount: "1")

      assert_instance_of Sdp::RampExecution, ramp
      assert_nil ramp.id
    end

    # -- sandbox simulate -------------------------------------------------------

    def test_simulate_ramp_posts_payload_and_returns_transaction_passthrough
      stub = stub_request(:post, "#{RAMPS}/sandbox/simulate")
        .with(body: { rampId: "rmp_1", event: "PAYMENT_RECEIVED" })
        .to_return(status: 200, headers: json_headers,
                   body: { data: { transaction: { id: "tx_1", status: "settled" } }, meta: {} }.to_json)

      tx = @client.simulate_ramp(rampId: "rmp_1", event: "PAYMENT_RECEIVED")

      assert_requested(stub)
      assert_equal({ id: "tx_1", status: "settled" }, tx)
    end

    def test_simulate_ramp_returns_nil_on_empty_body
      stub_request(:post, "#{RAMPS}/sandbox/simulate").to_return(status: 200, body: "")
      assert_nil @client.simulate_ramp(rampId: "rmp_1")
    end

    # -- writes never retry -----------------------------------------------------

    def test_execute_connection_reset_raises_timeout_and_is_not_retried
      stub = stub_request(:post, "#{RAMPS}/onramp/execute").to_raise(Errno::ECONNRESET)

      error = assert_raises(Sdp::Timeout) do
        @client.onramp_execute(provider: "bvnk", counterparty_id: "cp_1", destination_wallet: "wal_a",
                               crypto_token: "SOL", fiat_currency: "USD", fiat_amount: "1")
      end
      refute_instance_of Sdp::Unavailable, error
      assert_requested(stub, times: 1) # a re-sent ramp moves money twice
    end

    # -- error path -------------------------------------------------------------

    def test_quote_for_unsupported_pair_surfaces_bad_request
      stub_request(:post, "#{RAMPS}/onramp/quote")
        .to_return(status: 400, headers: json_headers,
                   body: { error: { code: "VALIDATION_ERROR", message: "Unsupported currency pair" },
                           meta: {} }.to_json)

      error = assert_raises(Sdp::BadRequest) do
        @client.onramp_quote(provider: "bvnk", counterparty_id: "cp_1", destination_wallet: "wal_a",
                             crypto_token: "SOL", fiat_currency: "ZZZ", fiat_amount: "1")
      end
      assert_equal "Unsupported currency pair", error.message
      assert_equal "VALIDATION_ERROR", error.code
    end

    private

    def json_headers
      { "Content-Type" => "application/json" }
    end
  end
end
