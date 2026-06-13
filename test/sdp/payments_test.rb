# frozen_string_literal: true

require "test_helper"

module Sdp
  class PaymentsTest < Minitest::Test
    BASE_URL = "http://sdp.test:8787"
    TRANSFERS_URL = "#{BASE_URL}/v1/payments/transfers".freeze
    PREPARE_URL = "#{BASE_URL}/v1/payments/transfers/prepare".freeze

    def setup
      @client = Sdp::Client.new(base_url: BASE_URL, api_key: "test-key")
    end

    # -- create_transfer --------------------------------------------------------

    def test_create_transfer_posts_sol_transfer_and_returns_transfer_struct
      stub = stub_request(:post, TRANSFERS_URL)
        .with(body: { source: "wal_a", destination: "Dest58Base", token: "SOL", amount: "0.25", memo: "rent" })
        .to_return(
          status: 201,
          headers: json_headers,
          body: {
            data: {
              transfer: {
                id: "tr_1",
                direction: "outbound",
                status: "confirmed",
                signature: "5sigBase58",
                token: "SOL",
                amount: "0.25",
                source: "wal_a",
                destination: "Dest58Base",
                memo: "rent",
                createdAt: "2026-06-12T10:00:00Z"
              }
            },
            meta: { requestId: "req-tr" }
          }.to_json
        )

      transfer = @client.create_transfer(source: "wal_a", destination: "Dest58Base", amount: "0.25", memo: "rent")

      assert_requested(stub)
      assert_instance_of Sdp::Transfer, transfer
      assert_equal "tr_1", transfer.id
      assert_equal "confirmed", transfer.status
      assert_equal "5sigBase58", transfer.signature
      assert_equal "SOL", transfer.token
      assert_equal "0.25", transfer.amount
      assert_equal "wal_a", transfer.source
      assert_equal "Dest58Base", transfer.destination
      assert_equal "rent", transfer.memo
      assert_equal "2026-06-12T10:00:00Z", transfer.created_at
      assert_nil transfer.error
    end

    def test_create_transfer_defaults_token_to_sol_and_omits_memo_when_nil
      stub = stub_request(:post, TRANSFERS_URL)
        .with(body: { source: "wal_a", destination: "dest", token: "SOL", amount: "1" })
        .to_return(status: 201, headers: json_headers, body: transfer_body("tr_2"))

      @client.create_transfer(source: "wal_a", destination: "dest", amount: 1)
      assert_requested(stub)
    end

    def test_create_transfer_passes_a_mint_address_token_through
      stub = stub_request(:post, TRANSFERS_URL)
        .with(body: { source: "wal_a", destination: "dest",
                      token: "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v", amount: "2" })
        .to_return(status: 201, headers: json_headers, body: transfer_body("tr_3"))

      @client.create_transfer(source: "wal_a", destination: "dest", amount: "2",
                              token: "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v")
      assert_requested(stub)
    end

    # -- prepare_transfer -------------------------------------------------------

    def test_prepare_transfer_returns_prepared_transaction_fields_and_transfer
      stub = stub_request(:post, PREPARE_URL)
        .with(body: { source: "wal_a", destination: "dest", token: "SOL", amount: "0.5" })
        .to_return(
          status: 200,
          headers: json_headers,
          body: {
            data: {
              transfer: {
                id: "tr_p1",
                status: "pending",
                token: "SOL",
                amount: "0.5",
                source: "wal_a",
                destination: "dest",
                createdAt: "2026-06-12T11:00:00Z"
              },
              preparedTransaction: {
                serialized: "AQABAgM=base64tx",
                blockhash: "Hash58Base",
                lastValidBlockHeight: 312456789
              },
              simulation: { unitsConsumed: 450, err: nil }
            },
            meta: { requestId: "req-prep" }
          }.to_json
        )

      prepared = @client.prepare_transfer(source: "wal_a", destination: "dest", amount: "0.5")

      assert_requested(stub)
      assert_instance_of Sdp::PreparedTransfer, prepared
      assert_equal "AQABAgM=base64tx", prepared.serialized
      assert_equal "Hash58Base", prepared.blockhash
      assert_equal 312_456_789, prepared.last_valid_block_height
      assert_instance_of Sdp::Transfer, prepared.transfer
      assert_equal "tr_p1", prepared.transfer.id
      assert_equal "pending", prepared.transfer.status
      assert_equal({ units_consumed: 450, err: nil }, prepared.simulation) # passthrough
    end

    def test_prepare_transfer_sends_reference_address_and_options_when_given
      stub = stub_request(:post, PREPARE_URL)
        .with(body: { source: "wal_a", destination: "dest", token: "SOL", amount: "1",
                      referenceAddress: "Ref58Base", options: { simulate: true } })
        .to_return(status: 200, headers: json_headers,
                   body: { data: { transfer: { id: "tr_p2" },
                                   preparedTransaction: { serialized: "x", blockhash: "h",
                                                          lastValidBlockHeight: 1 } },
                           meta: {} }.to_json)

      prepared = @client.prepare_transfer(source: "wal_a", destination: "dest", amount: "1",
                                          reference_address: "Ref58Base", options: { simulate: true })

      assert_requested(stub)
      assert_nil prepared.simulation # absent upstream → nil
    end

    # -- get_transfer -----------------------------------------------------------

    def test_get_transfer_unwraps_data_transfer
      stub_request(:get, "#{TRANSFERS_URL}/tr_1")
        .to_return(
          status: 200,
          headers: json_headers,
          body: {
            data: {
              transfer: {
                id: "tr_1", direction: "outbound", status: "finalized", signature: "sigA",
                token: "SOL", amount: "0.25", source: "wal_a", destination: "dest",
                createdAt: "2026-06-12T10:00:00Z"
              }
            },
            meta: { requestId: "req-get" }
          }.to_json
        )

      transfer = @client.get_transfer("tr_1")

      assert_equal "tr_1", transfer.id
      assert_equal "finalized", transfer.status
      assert_equal "sigA", transfer.signature
    end

    # -- fix A: empty 2xx body → all-nil struct, no NoMethodError -----------------

    def test_create_transfer_empty_200_body_returns_all_nil_transfer_struct
      stub_request(:post, TRANSFERS_URL)
        .to_return(status: 200, body: "")

      transfer = @client.create_transfer(source: "wal_a", destination: "dest", amount: "1")

      assert_instance_of Sdp::Transfer, transfer
      assert_nil transfer.id
      assert_nil transfer.status
    end

    def test_get_transfer_empty_200_body_returns_all_nil_transfer_struct
      stub_request(:get, "#{TRANSFERS_URL}/tr_empty")
        .to_return(status: 200, body: "")

      transfer = @client.get_transfer("tr_empty")

      assert_instance_of Sdp::Transfer, transfer
      assert_nil transfer.id
      assert_nil transfer.status
    end

    # -- fix B: id-in-path percent-encoding -------------------------------------

    def test_get_transfer_percent_encodes_space_in_id
      stub = stub_request(:get, "#{TRANSFERS_URL}/tr%201")
        .to_return(status: 200, headers: json_headers, body: transfer_body("tr 1"))

      @client.get_transfer("tr 1")
      assert_requested(stub)
    end

    def test_get_transfer_percent_encodes_query_chars_in_id
      stub = stub_request(:get, "#{TRANSFERS_URL}/tr%3Fx%3D1")
        .to_return(status: 200, headers: json_headers, body: transfer_body("tr?x=1"))

      @client.get_transfer("tr?x=1")
      assert_requested(stub)
    end

    # -- omitted optional fields (SDP omits, never nulls) -----------------------

    def test_transfer_with_omitted_optional_fields_builds_struct_with_nils
      stub_request(:get, "#{TRANSFERS_URL}/tr_sparse")
        .to_return(
          status: 200,
          headers: json_headers,
          body: {
            data: {
              transfer: { id: "tr_sparse", status: "processing", token: "SOL",
                          createdAt: "2026-06-12T12:00:00Z" }
            },
            meta: {}
          }.to_json
        )

      transfer = @client.get_transfer("tr_sparse")

      assert_equal "tr_sparse", transfer.id
      assert_equal "processing", transfer.status
      assert_nil transfer.source
      assert_nil transfer.destination
      assert_nil transfer.amount
      assert_nil transfer.memo
      assert_nil transfer.signature
      assert_nil transfer.error
    end

    def test_failed_transfer_exposes_the_error_field
      stub_request(:get, "#{TRANSFERS_URL}/tr_bad")
        .to_return(
          status: 200,
          headers: json_headers,
          body: {
            data: {
              transfer: { id: "tr_bad", status: "failed", token: "SOL",
                          error: "Transaction simulation failed: insufficient lamports" }
            },
            meta: {}
          }.to_json
        )

      transfer = @client.get_transfer("tr_bad")

      assert_equal "failed", transfer.status
      assert_equal "Transaction simulation failed: insufficient lamports", transfer.error
    end

    # -- error path -------------------------------------------------------------

    def test_list_transfers_with_invalid_status_surfaces_bad_request_with_field_errors
      stub_request(:get, TRANSFERS_URL)
        .with(query: { "status" => "bogus" })
        .to_return(
          status: 400,
          headers: json_headers,
          body: {
            error: {
              code: "VALIDATION_ERROR",
              message: "Invalid query parameters",
              details: {
                fieldErrors: {
                  status: [ "must be one of: pending, processing, confirmed, finalized, failed" ]
                }
              }
            },
            meta: { requestId: "req-err" }
          }.to_json
        )

      error = assert_raises(Sdp::BadRequest) { @client.list_transfers(status: "bogus").to_a }

      assert_equal "Invalid query parameters", error.message
      assert_equal "VALIDATION_ERROR", error.code
      assert_equal 400, error.http_status
      assert_equal(
        { field_errors: { status: [ "must be one of: pending, processing, confirmed, finalized, failed" ] } },
        error.details
      )
    end

    private

    def json_headers
      { "Content-Type" => "application/json" }
    end

    def transfer_body(id)
      {
        data: {
          transfer: {
            id: id, direction: "outbound", status: "confirmed", signature: "sig",
            token: "SOL", amount: "1", source: "wal_a", destination: "dest",
            createdAt: "2026-06-12T10:00:00Z"
          }
        },
        meta: {}
      }.to_json
    end
  end
end
