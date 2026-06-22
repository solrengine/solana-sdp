# frozen_string_literal: true

require "test_helper"

module Sdp
  class WalletsTest < Minitest::Test
    BASE_URL = "http://sdp.test:8787"
    WALLETS_URL = "#{BASE_URL}/v1/wallets".freeze
    INITIALIZE_URL = "#{BASE_URL}/v1/wallets/initialize".freeze

    def setup
      @client = Sdp::Client.new(base_url: BASE_URL, api_key: "test-key")
    end

    # -- initialize_custody -----------------------------------------------------

    def test_initialize_custody_posts_without_a_body_and_returns_snake_cased_data
      stub = stub_request(:post, INITIALIZE_URL)
        .with { |request| request.body.nil? || request.body.empty? }
        .to_return(
          status: 201,
          headers: json_headers,
          body: {
            data: {
              provider: "local",
              custodyStatus: "initialized",
              wallet: {
                id: "row-1",
                walletId: "wal_root",
                publicKey: "RootPubKeyBase58",
                label: "project-root",
                purpose: "root",
                status: "active",
                createdAt: "2026-06-12T08:00:00Z"
              }
            },
            meta: { requestId: "req-init" }
          }.to_json
        )

      data = @client.initialize_custody

      assert_requested(stub)
      assert_equal "local", data[:provider]
      assert_equal "initialized", data[:custody_status]
      assert_equal "wal_root", data[:wallet][:wallet_id]
      assert_equal "RootPubKeyBase58", data[:wallet][:public_key]
    end

    def test_initialize_custody_sends_provider_and_camel_cased_wallet_label
      stub = stub_request(:post, INITIALIZE_URL)
        .with(body: { provider: "privy", walletLabel: "treasury-root" })
        .to_return(status: 201, headers: json_headers,
                   body: { data: { provider: "privy" }, meta: {} }.to_json)

      @client.initialize_custody(provider: "privy", wallet_label: "treasury-root")
      assert_requested(stub)
    end

    # -- create_wallet ----------------------------------------------------------

    def test_create_wallet_maps_wallet_id_to_struct_id_and_exposes_v028_fields
      stub = stub_request(:post, WALLETS_URL)
        .with(body: { label: "user-9", provider: "privy" })
        .to_return(
          status: 201,
          headers: json_headers,
          body: {
            data: {
              wallet: {
                id: "row-9",
                walletId: "wal_9",
                publicKey: "PubKey9Base58",
                label: "user-9",
                purpose: "user",
                status: "active",
                createdAt: "2026-06-12T09:00:00Z"
              }
            },
            meta: { requestId: "req-9" }
          }.to_json
        )

      wallet = @client.create_wallet(label: "user-9", provider: "privy")

      assert_requested(stub)
      assert_instance_of Sdp::Wallet, wallet
      assert_equal "wal_9", wallet.id # walletId, not the db row id
      assert_equal "PubKey9Base58", wallet.public_key
      assert_equal "user-9", wallet.label
      assert_equal "user", wallet.purpose
      assert_equal "active", wallet.status
      assert_equal "2026-06-12T09:00:00Z", wallet.created_at
    end

    def test_create_wallet_omits_provider_from_the_body_when_nil
      stub = stub_request(:post, WALLETS_URL)
        .with(body: { label: "treasury" })
        .to_return(status: 201, headers: json_headers,
                   body: { data: { wallet: { walletId: "wal_t", publicKey: "pk" } }, meta: {} }.to_json)

      @client.create_wallet(label: "treasury")
      assert_requested(stub)
    end

    # -- fix A: empty 2xx body → all-nil struct, no NoMethodError -----------------

    def test_create_wallet_empty_200_body_returns_all_nil_wallet_struct
      stub_request(:post, WALLETS_URL)
        .with(body: { label: "empty-test" })
        .to_return(status: 200, body: "")

      wallet = @client.create_wallet(label: "empty-test")

      assert_instance_of Sdp::Wallet, wallet
      assert_nil wallet.id
      assert_nil wallet.public_key
    end

    # -- list_wallets -----------------------------------------------------------

    def test_list_wallets_returns_wallet_structs_in_a_single_request
      stub = stub_request(:get, WALLETS_URL)
        .to_return(
          status: 200,
          headers: json_headers,
          body: {
            data: {
              wallets: [
                { id: "row-1", walletId: "wal_1", publicKey: "PubKeyA", label: "user-1",
                  purpose: "user", status: "active", createdAt: "2026-06-10T12:00:00Z" },
                { id: "row-2", walletId: "wal_2", publicKey: "PubKeyB", label: "treasury",
                  purpose: "root", status: "active", createdAt: "2026-06-09T12:00:00Z" }
              ]
            },
            meta: { requestId: "req-list" }
          }.to_json
        )

      wallets = @client.list_wallets

      # Not paginated at v0.31: the shared list helper must stop after one
      # fetch when meta carries no hasMore (and send no page params).
      assert_requested(stub, times: 1)
      assert_instance_of Array, wallets
      assert_equal %w[wal_1 wal_2], wallets.map(&:id)
      assert_equal "PubKeyA", wallets.first.public_key
      assert_equal "root", wallets.last.purpose
    end

    def test_list_wallets_sends_camel_cased_filters
      stub = stub_request(:get, WALLETS_URL)
        .with(query: { "provider" => "privy", "projectId" => "proj_1", "includeBalances" => "true" })
        .to_return(status: 200, headers: json_headers,
                   body: { data: { wallets: [] }, meta: {} }.to_json)

      @client.list_wallets(provider: "privy", project_id: "proj_1", include_balances: true)
      assert_requested(stub)
    end

    def test_list_wallets_maps_included_balances_to_balance_structs
      stub_request(:get, WALLETS_URL)
        .with(query: { "includeBalances" => "true" })
        .to_return(
          status: 200,
          headers: json_headers,
          body: {
            data: {
              wallets: [
                {
                  walletId: "wal_1", publicKey: "PubKeyA", label: "user-1", status: "active",
                  balances: [
                    { token: "SOL", mint: "So11111111111111111111111111111111111111112",
                      amount: "1500000000", uiAmount: "1.5", decimals: 9 }
                  ]
                }
              ]
            },
            meta: {}
          }.to_json
        )

      wallet = @client.list_wallets(include_balances: true).first

      assert_instance_of Sdp::Balance, wallet.balances.first
      assert_equal "SOL", wallet.balances.first.token
      assert_equal "1.5", wallet.balances.first.ui_amount
    end

    def test_list_wallets_returns_empty_array_for_empty_list
      stub_request(:get, WALLETS_URL)
        .to_return(status: 200, headers: json_headers,
                   body: { data: { wallets: [] }, meta: {} }.to_json)

      assert_equal [], @client.list_wallets
    end

    # -- wallet_balances --------------------------------------------------------

    def test_wallet_balances_returns_balance_structs_with_usd_value_when_present
      stub_request(:get, balances_url("wal_1"))
        .to_return(
          status: 200,
          headers: json_headers,
          body: {
            data: {
              walletBalances: {
                walletId: "wal_1",
                address: "PubKeyABase58",
                balances: [
                  { token: "SOL", mint: "So11111111111111111111111111111111111111112",
                    amount: "1500000000", uiAmount: "1.5", decimals: 9, usdValue: "225.38" },
                  { token: "USDC", mint: "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v",
                    amount: "2000000", uiAmount: "2", decimals: 6, usdValue: "2.00" }
                ]
              }
            },
            meta: { requestId: "req-bal" }
          }.to_json
        )

      balances = @client.wallet_balances("wal_1")

      assert_equal 2, balances.size
      sol = balances.first
      assert_instance_of Sdp::Balance, sol
      assert_equal "SOL", sol.token
      assert_equal "So11111111111111111111111111111111111111112", sol.mint
      assert_equal "1500000000", sol.amount # base units, string
      assert_equal "1.5", sol.ui_amount
      assert_equal 9, sol.decimals
      assert_equal "225.38", sol.usd_value # AE3: passthrough when present
    end

    def test_wallet_balances_without_usd_value_yields_nil_not_an_error
      stub_request(:get, balances_url("wal_1"))
        .to_return(
          status: 200,
          headers: json_headers,
          body: {
            data: {
              walletBalances: {
                walletId: "wal_1",
                address: "PubKeyABase58",
                balances: [
                  { token: "SOL", mint: "So11111111111111111111111111111111111111112",
                    amount: "1500000000", uiAmount: "1.5", decimals: 9 }
                ]
              }
            },
            meta: {}
          }.to_json
        )

      sol = @client.wallet_balances("wal_1").first

      assert_equal "1.5", sol.ui_amount
      assert_nil sol.usd_value # AE3: absent upstream → nil, no error
    end

    def test_wallet_balances_returns_empty_array_when_sdp_sends_none
      stub_request(:get, balances_url("wal_1"))
        .to_return(
          status: 200,
          headers: json_headers,
          body: { data: { walletBalances: { walletId: "wal_1", address: "x", balances: [] } }, meta: {} }.to_json
        )

      assert_equal [], @client.wallet_balances("wal_1")
    end

    # -- fix B: wallet_id-in-path percent-encoding ------------------------------

    def test_wallet_balances_percent_encodes_space_in_wallet_id
      stub = stub_request(:get, "#{BASE_URL}/v1/payments/wallets/wal%201/balances")
        .to_return(
          status: 200,
          headers: json_headers,
          body: { data: { walletBalances: { walletId: "wal 1", balances: [] } }, meta: {} }.to_json
        )

      @client.wallet_balances("wal 1")
      assert_requested(stub)
    end

    def test_wallet_balances_percent_encodes_query_chars_in_wallet_id
      stub = stub_request(:get, "#{BASE_URL}/v1/payments/wallets/wal%3Fx%3D1/balances")
        .to_return(
          status: 200,
          headers: json_headers,
          body: { data: { walletBalances: { walletId: "wal?x=1", balances: [] } }, meta: {} }.to_json
        )

      @client.wallet_balances("wal?x=1")
      assert_requested(stub)
    end

    private

    def balances_url(wallet_id)
      "#{BASE_URL}/v1/payments/wallets/#{wallet_id}/balances"
    end

    def json_headers
      { "Content-Type" => "application/json" }
    end
  end
end
