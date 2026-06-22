# frozen_string_literal: true

require "test_helper"

module Sdp
  class IssuanceTest < Minitest::Test
    BASE_URL = "http://sdp.test:8787"
    TOKENS_URL = "#{BASE_URL}/v1/issuance/tokens".freeze

    def setup
      @client = Sdp::Client.new(base_url: BASE_URL, api_key: "test-key")
    end

    # -- create_token -----------------------------------------------------------

    def test_create_token_posts_camelcased_payload_and_returns_token_struct
      stub = stub_request(:post, TOKENS_URL)
        .with(body: { name: "Acme USD", symbol: "AUSD", signingWalletId: "wal_a",
                      decimals: 6, maxSupply: "1000000", isMintable: true })
        .to_return(status: 201, headers: json_headers, body: token_body("tok_1", status: "created"))

      token = @client.create_token(name: "Acme USD", symbol: "AUSD", signing_wallet_id: "wal_a",
                                    decimals: 6, max_supply: "1000000", is_mintable: true)

      assert_requested(stub)
      assert_instance_of Sdp::Token, token
      assert_equal "tok_1", token.id
      assert_equal "AUSD", token.symbol
      assert_equal 6, token.decimals
      assert_equal "created", token.status
      assert_equal "wal_a", token.signing_wallet_id
    end

    def test_create_token_omits_nil_optional_fields
      stub = stub_request(:post, TOKENS_URL)
        .with(body: { name: "Bare", symbol: "BARE", signingWalletId: "wal_a" })
        .to_return(status: 201, headers: json_headers, body: token_body("tok_2"))

      @client.create_token(name: "Bare", symbol: "BARE", signing_wallet_id: "wal_a")
      assert_requested(stub)
    end

    # -- get_token --------------------------------------------------------------

    def test_get_token_unwraps_data_token
      stub_request(:get, "#{TOKENS_URL}/tok_1")
        .to_return(status: 200, headers: json_headers,
                   body: token_body("tok_1", status: "deployed", mint_address: "Mint58"))

      token = @client.get_token("tok_1")

      assert_equal "tok_1", token.id
      assert_equal "deployed", token.status
      assert_equal "Mint58", token.mint_address
    end

    def test_get_token_percent_encodes_id
      stub = stub_request(:get, "#{TOKENS_URL}/tok%201")
        .to_return(status: 200, headers: json_headers, body: token_body("tok 1"))

      @client.get_token("tok 1")
      assert_requested(stub)
    end

    def test_get_token_empty_200_body_returns_all_nil_struct
      stub_request(:get, "#{TOKENS_URL}/tok_empty").to_return(status: 200, body: "")

      token = @client.get_token("tok_empty")

      assert_instance_of Sdp::Token, token
      assert_nil token.id
      assert_nil token.status
    end

    def test_token_with_omitted_optional_fields_builds_struct_with_nils
      stub_request(:get, "#{TOKENS_URL}/tok_sparse")
        .to_return(status: 200, headers: json_headers,
                   body: { data: { token: { id: "tok_sparse", symbol: "SPR", status: "created" } },
                           meta: {} }.to_json)

      token = @client.get_token("tok_sparse")

      assert_equal "tok_sparse", token.id
      assert_nil token.mint_address
      assert_nil token.total_supply
      assert_nil token.deployed_at
    end

    def test_get_token_passes_extensions_through_untyped
      stub_request(:get, "#{TOKENS_URL}/tok_ext")
        .to_return(status: 200, headers: json_headers,
                   body: { data: { token: { id: "tok_ext", symbol: "EXT",
                                            extensions: { transferFee: { basisPoints: 50 } } } },
                           meta: {} }.to_json)

      token = @client.get_token("tok_ext")

      assert_equal({ transfer_fee: { basis_points: 50 } }, token.extensions)
    end

    # -- list_tokens ------------------------------------------------------------

    def test_list_tokens_yields_token_structs_and_sends_filters
      stub = stub_request(:get, TOKENS_URL)
        .with(query: { "status" => "deployed" })
        .to_return(status: 200, headers: json_headers,
                   body: { data: [ { id: "tok_a", symbol: "A" }, { id: "tok_b", symbol: "B" } ],
                           meta: { hasMore: false } }.to_json)

      tokens = @client.list_tokens(status: "deployed").to_a

      assert_requested(stub)
      assert_equal %w[tok_a tok_b], tokens.map(&:id)
      assert(tokens.all? { |t| t.is_a?(Sdp::Token) })
    end

    def test_list_tokens_auto_paginates_on_has_more
      # First page: bare stub (matches the no-query request); page 2: explicit
      # query, declared later so WebMock prefers it for ?page=2.
      stub_request(:get, TOKENS_URL)
        .to_return(status: 200, headers: json_headers,
                   body: { data: [ { id: "tok_a" } ], meta: { hasMore: true } }.to_json)
      page2 = stub_request(:get, TOKENS_URL)
        .with(query: { "page" => "2" })
        .to_return(status: 200, headers: json_headers,
                   body: { data: [ { id: "tok_b" } ], meta: { hasMore: false } }.to_json)

      tokens = @client.list_tokens.to_a

      assert_requested(page2)
      assert_equal %w[tok_a tok_b], tokens.map(&:id)
    end

    # -- deploy_token -----------------------------------------------------------

    def test_deploy_token_posts_to_deploy_and_returns_updated_token
      stub = stub_request(:post, "#{TOKENS_URL}/tok_1/deploy")
        .to_return(status: 200, headers: json_headers,
                   body: token_body("tok_1", status: "deployed", mint_address: "Mint58"))

      token = @client.deploy_token("tok_1")

      assert_requested(stub)
      assert_equal "deployed", token.status
      assert_equal "Mint58", token.mint_address
    end

    def test_prepare_deploy_returns_unsigned_envelope_and_mint
      stub_request(:post, "#{TOKENS_URL}/tok_1/deploy/prepare")
        .to_return(status: 200, headers: json_headers,
                   body: { data: { transaction: { serialized: "AQ==deploytx", blockhash: "Hash58",
                                                  lastValidBlockHeight: 321 },
                                   mint: "Mint58", simulation: { success: true } },
                           meta: {} }.to_json)

      prepared = @client.prepare_deploy("tok_1")

      assert_instance_of Sdp::PreparedTokenTransaction, prepared
      assert_nil prepared.transaction # deploy/prepare carries no action record
      assert_equal "AQ==deploytx", prepared.serialized
      assert_equal "Hash58", prepared.blockhash
      assert_equal 321, prepared.last_valid_block_height
      assert_equal "Mint58", prepared.mint
      assert_equal({ success: true }, prepared.simulation)
    end

    # -- mint -------------------------------------------------------------------

    def test_mint_posts_nested_payload_and_returns_token_transaction_with_account
      stub = stub_request(:post, "#{TOKENS_URL}/tok_1/mint")
        .with(body: { signingWalletId: "wal_a",
                      mint: { destination: "Dest58", amount: "1000", memo: "seed" } })
        .to_return(status: 200, headers: json_headers,
                   body: { data: { transaction: tx_hash("itx_1", type: "mint", status: "confirmed"),
                                   tokenAccount: "Ata58" },
                           meta: {} }.to_json)

      tx = @client.mint("tok_1", signing_wallet_id: "wal_a", destination: "Dest58", amount: 1000, memo: "seed")

      assert_requested(stub)
      assert_instance_of Sdp::TokenTransaction, tx
      assert_equal "itx_1", tx.id
      assert_equal "mint", tx.type
      assert_equal "confirmed", tx.status
      assert_equal "Ata58", tx.token_account
    end

    def test_mint_omits_memo_when_nil_and_stringifies_amount
      stub = stub_request(:post, "#{TOKENS_URL}/tok_1/mint")
        .with(body: { signingWalletId: "wal_a", mint: { destination: "Dest58", amount: "5" } })
        .to_return(status: 200, headers: json_headers,
                   body: { data: { transaction: tx_hash("itx_2") }, meta: {} }.to_json)

      tx = @client.mint("tok_1", signing_wallet_id: "wal_a", destination: "Dest58", amount: 5)

      assert_requested(stub)
      assert_nil tx.token_account # absent upstream → nil
    end

    def test_mint_empty_200_body_returns_all_nil_token_transaction
      stub_request(:post, "#{TOKENS_URL}/tok_1/mint").to_return(status: 200, body: "")

      tx = @client.mint("tok_1", signing_wallet_id: "wal_a", destination: "Dest58", amount: "1")

      assert_instance_of Sdp::TokenTransaction, tx
      assert_nil tx.id
      assert_nil tx.token_account
    end

    def test_mint_non_hash_data_envelope_degrades_to_all_nil_not_typeerror
      # A money-path write must never raise a raw TypeError on an off-shape 200.
      stub_request(:post, "#{TOKENS_URL}/tok_1/mint")
        .to_return(status: 200, headers: json_headers, body: { data: [ "unexpected" ], meta: {} }.to_json)

      tx = @client.mint("tok_1", signing_wallet_id: "wal_a", destination: "Dest58", amount: "1")

      assert_instance_of Sdp::TokenTransaction, tx
      assert_nil tx.id
      assert_nil tx.token_account
    end

    def test_prepare_mint_returns_record_and_unsigned_envelope
      stub_request(:post, "#{TOKENS_URL}/tok_1/mint/prepare")
        .to_return(status: 200, headers: json_headers,
                   body: { data: { transaction: tx_hash("itx_p1", status: "pending"),
                                   preparedTransaction: { serialized: "AQ==minttx", blockhash: "H",
                                                          lastValidBlockHeight: 9 },
                                   tokenAccount: "Ata58", simulation: { success: true } },
                           meta: {} }.to_json)

      prepared = @client.prepare_mint("tok_1", signing_wallet_id: "wal_a", destination: "Dest58", amount: "1")

      assert_instance_of Sdp::PreparedTokenTransaction, prepared
      assert_instance_of Sdp::TokenTransaction, prepared.transaction
      assert_equal "itx_p1", prepared.transaction.id
      assert_equal "Ata58", prepared.transaction.token_account
      assert_equal "AQ==minttx", prepared.serialized
      assert_equal 9, prepared.last_valid_block_height
    end

    # -- burn -------------------------------------------------------------------

    def test_burn_posts_nested_payload_and_returns_token_transaction
      stub = stub_request(:post, "#{TOKENS_URL}/tok_1/burn")
        .with(body: { signingWalletId: "wal_a", burn: { source: "Src58", amount: "250" } })
        .to_return(status: 200, headers: json_headers,
                   body: { data: { transaction: tx_hash("itx_b1", type: "burn", status: "confirmed") },
                           meta: {} }.to_json)

      tx = @client.burn("tok_1", signing_wallet_id: "wal_a", source: "Src58", amount: 250)

      assert_requested(stub)
      assert_equal "itx_b1", tx.id
      assert_equal "burn", tx.type
      assert_nil tx.token_account # burn returns no token account
    end

    def test_prepare_burn_returns_record_and_unsigned_envelope
      stub_request(:post, "#{TOKENS_URL}/tok_1/burn/prepare")
        .to_return(status: 200, headers: json_headers,
                   body: { data: { transaction: tx_hash("itx_pb1", status: "pending"),
                                   preparedTransaction: { serialized: "AQ==burntx", blockhash: "H",
                                                          lastValidBlockHeight: 11 },
                                   simulation: { success: true } },
                           meta: {} }.to_json)

      prepared = @client.prepare_burn("tok_1", signing_wallet_id: "wal_a", source: "Src58", amount: "1")

      assert_instance_of Sdp::PreparedTokenTransaction, prepared
      assert_equal "itx_pb1", prepared.transaction.id
      assert_nil prepared.transaction.token_account # burn/prepare carries no token account, unlike mint
      assert_equal "AQ==burntx", prepared.serialized
      assert_equal 11, prepared.last_valid_block_height
    end

    # -- writes are never retried (double-mint hazard) ---------------------------

    # A mid-flight reset on a mint has an unknown outcome — the body may already
    # have been processed on-chain — so it must surface as Timeout (reconcile
    # before re-sending), never a retryable Unavailable, and never be retried.
    def test_mint_connection_reset_raises_timeout_and_is_not_retried
      stub = stub_request(:post, "#{TOKENS_URL}/tok_1/mint").to_raise(Errno::ECONNRESET)

      error = assert_raises(Sdp::Timeout) do
        @client.mint("tok_1", signing_wallet_id: "wal_a", destination: "Dest58", amount: "1")
      end
      refute_instance_of Sdp::Unavailable, error
      assert_requested(stub, times: 1) # exactly one attempt — a re-sent mint risks a double-mint
    end

    # burn and deploy share the same money-path post() — the no-retry/Timeout
    # guarantee the module comment claims for all three must hold for them too.
    def test_burn_connection_reset_raises_timeout_and_is_not_retried
      stub = stub_request(:post, "#{TOKENS_URL}/tok_1/burn").to_raise(Errno::ECONNRESET)

      error = assert_raises(Sdp::Timeout) do
        @client.burn("tok_1", signing_wallet_id: "wal_a", source: "Src58", amount: "1")
      end
      refute_instance_of Sdp::Unavailable, error
      assert_requested(stub, times: 1)
    end

    def test_deploy_token_connection_reset_raises_timeout_and_is_not_retried
      stub = stub_request(:post, "#{TOKENS_URL}/tok_1/deploy").to_raise(Errno::ECONNRESET)

      error = assert_raises(Sdp::Timeout) { @client.deploy_token("tok_1") }
      refute_instance_of Sdp::Unavailable, error
      assert_requested(stub, times: 1)
    end

    # -- error path -------------------------------------------------------------

    def test_mint_on_non_mintable_token_surfaces_bad_request
      stub_request(:post, "#{TOKENS_URL}/tok_1/mint")
        .to_return(status: 400, headers: json_headers,
                   body: { error: { code: "VALIDATION_ERROR", message: "Token is not mintable" },
                           meta: { requestId: "req-err" } }.to_json)

      error = assert_raises(Sdp::BadRequest) do
        @client.mint("tok_1", signing_wallet_id: "wal_a", destination: "Dest58", amount: "1")
      end

      assert_equal "Token is not mintable", error.message
      assert_equal "VALIDATION_ERROR", error.code
      assert_equal 400, error.http_status
    end

    private

    def json_headers
      { "Content-Type" => "application/json" }
    end

    def token_body(id, status: "created", mint_address: nil)
      token = { id: id, projectId: "proj_1", signingWalletId: "wal_a", name: "Acme USD",
                symbol: "AUSD", decimals: 6, status: status, createdAt: "2026-06-22T10:00:00Z" }
      token[:mintAddress] = mint_address if mint_address
      { data: { token: token }, meta: { requestId: "req" } }.to_json
    end

    def tx_hash(id, type: "mint", status: "confirmed")
      { id: id, tokenId: "tok_1", type: type, status: status, signature: "sig58",
        serializedTx: "AQ==tx", slot: 100, fee: 5000, createdAt: "2026-06-22T10:00:00Z" }
    end
  end
end
