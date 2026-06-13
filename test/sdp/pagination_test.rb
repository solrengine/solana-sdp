# frozen_string_literal: true

require "test_helper"

module Sdp
  class PaginationTest < Minitest::Test
    BASE_URL = "http://sdp.test:8787"
    TRANSFERS_URL = "#{BASE_URL}/v1/payments/transfers".freeze

    def setup
      @client = Sdp::Client.new(base_url: BASE_URL, api_key: "test-key")
    end

    # -- auto-pagination across pages -------------------------------------------

    def test_enumerator_follows_has_more_across_three_pages
      page1 = stub_page({ "wallet" => "wal_1" },
                        rows: [ transfer_row("tr_1"), transfer_row("tr_2") ],
                        meta: { total: 5, page: 1, pageSize: 2, hasMore: true })
      page2 = stub_page({ "wallet" => "wal_1", "page" => "2" },
                        rows: [ transfer_row("tr_3"), transfer_row("tr_4") ],
                        meta: { total: 5, page: 2, pageSize: 2, hasMore: true })
      page3 = stub_page({ "wallet" => "wal_1", "page" => "3" },
                        rows: [ transfer_row("tr_5") ],
                        meta: { total: 5, page: 3, pageSize: 2, hasMore: false })

      transfers = @client.list_transfers(wallet: "wal_1").to_a

      assert_equal %w[tr_1 tr_2 tr_3 tr_4 tr_5], transfers.map(&:id)
      assert_instance_of Sdp::Transfer, transfers.first
      assert_requested(page1, times: 1)
      assert_requested(page2, times: 1)
      assert_requested(page3, times: 1)
    end

    def test_enumerator_is_lazy_page_two_is_not_fetched_until_iteration_reaches_it
      stub_page({ "wallet" => "wal_1" },
                rows: [ transfer_row("tr_1"), transfer_row("tr_2") ],
                meta: { total: 3, page: 1, pageSize: 2, hasMore: true })
      page2 = stub_page({ "wallet" => "wal_1", "page" => "2" },
                        rows: [ transfer_row("tr_3") ],
                        meta: { total: 3, page: 2, pageSize: 2, hasMore: false })

      enum = @client.list_transfers(wallet: "wal_1")
      assert_not_requested(page2) # building the enumerator fetches nothing

      first_two = enum.take(2) # fully served by page 1

      assert_equal %w[tr_1 tr_2], first_two.map(&:id)
      assert_not_requested(page2) # page 2 untouched until iteration needs it

      assert_equal %w[tr_1 tr_2 tr_3], enum.to_a.map(&:id)
      assert_requested(page2, times: 1)
    end

    def test_filters_are_passed_through_on_every_page
      page1 = stub_page({ "wallet" => "wal_1", "token" => "SOL", "direction" => "outbound" },
                        rows: [ transfer_row("tr_1") ],
                        meta: { total: 2, page: 1, pageSize: 1, hasMore: true })
      page2 = stub_page({ "wallet" => "wal_1", "token" => "SOL", "direction" => "outbound", "page" => "2" },
                        rows: [ transfer_row("tr_2") ],
                        meta: { total: 2, page: 2, pageSize: 1, hasMore: false })

      ids = @client.list_transfers(wallet: "wal_1", token: "SOL", direction: "outbound").map(&:id)

      assert_equal %w[tr_1 tr_2], ids
      assert_requested(page1, times: 1)
      assert_requested(page2, times: 1) # same filters, page bumped
    end

    def test_single_page_response_makes_exactly_one_request
      stub = stub_page({ "wallet" => "wal_1" },
                       rows: [ transfer_row("tr_1") ],
                       meta: { total: 1, page: 1, pageSize: 20, hasMore: false })

      assert_equal %w[tr_1], @client.list_transfers(wallet: "wal_1").map(&:id)
      assert_requested(stub, times: 1)
    end

    def test_empty_list_returns_an_empty_enumerator
      stub_page({}, rows: [], meta: { total: 0, page: 1, pageSize: 20, hasMore: false })

      enum = @client.list_transfers

      assert_equal 0, enum.count
      assert_equal [], enum.to_a
    end

    # -- explicit page: single-page mode -----------------------------------------

    def test_explicit_page_fetches_only_that_page_even_when_has_more_is_true
      stub = stub_page({ "wallet" => "wal_1", "page" => "2" },
                       rows: [ transfer_row("tr_3"), transfer_row("tr_4") ],
                       meta: { total: 6, page: 2, pageSize: 2, hasMore: true })

      transfers = @client.list_transfers(wallet: "wal_1", page: 2).to_a

      # Any page-3 request would hit an unstubbed URL and fail the test.
      assert_equal %w[tr_3 tr_4], transfers.map(&:id)
      assert_requested(stub, times: 1)
    end

    # -- page size ----------------------------------------------------------------

    def test_page_size_passes_through_under_the_cap
      stub = stub_page({ "pageSize" => "50" },
                       rows: [], meta: { total: 0, page: 1, pageSize: 50, hasMore: false })

      @client.list_transfers(page_size: 50).to_a
      assert_requested(stub)
    end

    def test_page_size_is_clamped_client_side_to_100
      stub = stub_page({ "pageSize" => "100" },
                       rows: [], meta: { total: 0, page: 1, pageSize: 100, hasMore: false })

      @client.list_transfers(page_size: 250).to_a
      assert_requested(stub)
    end

    # -- status filter shaping ------------------------------------------------------

    def test_status_array_is_sent_comma_separated
      stub = stub_page({ "status" => "confirmed,finalized" },
                       rows: [], meta: { total: 0, page: 1, pageSize: 20, hasMore: false })

      @client.list_transfers(status: %w[confirmed finalized]).to_a
      assert_requested(stub)
    end

    # -- loop guard -------------------------------------------------------------

    def test_has_more_with_an_empty_page_stops_instead_of_looping_forever
      stub_page({}, rows: [], meta: { total: 0, page: 1, pageSize: 20, hasMore: true })

      assert_equal [], @client.list_transfers.to_a
    end

    # -- server-controlled page echo (P2 regression) ------------------------------

    def test_lying_server_repeating_meta_page_does_not_loop_forever
      # Server always echoes page:1 in meta even as the client requests 2, 3.
      # With a server-driven counter the client would request page:1 forever;
      # with a LOCAL counter it advances 1→2→3 and terminates on hasMore:false.
      page1 = stub_page({ "wallet" => "wal_1" },
                        rows: [ transfer_row("tr_1"), transfer_row("tr_2") ],
                        meta: { total: 6, page: 1, pageSize: 2, hasMore: true })
      page2 = stub_page({ "wallet" => "wal_1", "page" => "2" },
                        rows: [ transfer_row("tr_3"), transfer_row("tr_4") ],
                        meta: { total: 6, page: 1, pageSize: 2, hasMore: true }) # lying: still page 1
      page3 = stub_page({ "wallet" => "wal_1", "page" => "3" },
                        rows: [ transfer_row("tr_5"), transfer_row("tr_6") ],
                        meta: { total: 6, page: 1, pageSize: 2, hasMore: false }) # lying: still page 1

      transfers = @client.list_transfers(wallet: "wal_1").to_a

      assert_equal %w[tr_1 tr_2 tr_3 tr_4 tr_5 tr_6], transfers.map(&:id)
      assert_requested(page1, times: 1)
      assert_requested(page2, times: 1) # client advanced to 2, not looped on 1
      assert_requested(page3, times: 1) # client advanced to 3, not looped on 1
    end

    def test_meta_page_as_string_does_not_raise_type_error
      # A server returning meta.page as a JSON string ("1") used to cause a
      # TypeError ("1" + 1).  The local counter never touches meta.page.
      page1 = stub_page({},
                        rows: [ transfer_row("tr_1") ],
                        meta: { total: 2, page: "1", pageSize: 1, hasMore: true })
      page2 = stub_page({ "page" => "2" },
                        rows: [ transfer_row("tr_2") ],
                        meta: { total: 2, page: "2", pageSize: 1, hasMore: false })

      transfers = @client.list_transfers.to_a

      assert_equal %w[tr_1 tr_2], transfers.map(&:id)
      assert_requested(page1, times: 1)
      assert_requested(page2, times: 1)
    end

    private

    def stub_page(query, rows:, meta:)
      stub = stub_request(:get, TRANSFERS_URL)
      stub = stub.with(query: query) unless query.empty?
      stub.to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { data: rows, meta: meta }.to_json
      )
    end

    def transfer_row(id)
      {
        id: id, direction: "outbound", status: "confirmed", signature: "sig-#{id}",
        token: "SOL", amount: "1", source: "wal_1", destination: "dest",
        createdAt: "2026-06-12T10:00:00Z"
      }
    end
  end
end
