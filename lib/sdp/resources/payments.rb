# frozen_string_literal: true

require "uri"

module Sdp
  # A transfer as SDP reports it. SDP omits optional fields entirely —
  # source/destination/amount/memo can be ABSENT from the JSON, not null —
  # so every member is nil when SDP didn't send it.
  Transfer = Struct.new(:id, :direction, :status, :signature, :token, :amount,
                        :source, :destination, :memo, :error, :created_at,
                        keyword_init: true) do
    def self.from_hash(hash)
      hash ||= {}
      new(
        id: hash[:id],
        direction: hash[:direction],
        status: hash[:status],
        signature: hash[:signature],
        token: hash[:token],
        amount: hash[:amount],
        source: hash[:source],
        destination: hash[:destination],
        memo: hash[:memo],
        error: hash[:error],
        created_at: hash[:created_at]
      )
    end
  end

  # Result of POST /v1/payments/transfers/prepare: the provisional transfer
  # plus the unsigned transaction the caller must sign and submit before
  # blockhash expiry. simulation is SDP's simulation result passed through
  # as a hash when present.
  PreparedTransfer = Struct.new(:transfer, :serialized, :blockhash, :last_valid_block_height, :simulation,
                                keyword_init: true) do
    def self.from_hash(hash)
      hash ||= {}
      prepared = hash[:prepared_transaction] || {}
      new(
        transfer: Transfer.from_hash(hash[:transfer]),
        serialized: prepared[:serialized],
        blockhash: prepared[:blockhash],
        last_valid_block_height: prepared[:last_valid_block_height],
        simulation: hash[:simulation]
      )
    end
  end

  module Resources
    # Payment endpoints: transfer create/prepare/list/get.
    module Payments
      # POST /v1/payments/transfers → Sdp::Transfer
      # Synchronous sign-and-send: SDP confirms before responding, and the
      # request is NEVER retried (no idempotency key upstream — see Client
      # docs). amount is serialized as a decimal string; token is "SOL" or
      # an SPL mint address.
      def create_transfer(source:, destination:, amount:, token: "SOL", memo: nil)
        response = post("/v1/payments/transfers", transfer_payload(source, destination, amount, token, memo))
        data = response.data
        src = data.is_a?(Hash) ? (data[:transfer] || data) : data
        Transfer.from_hash(src)
      end

      # POST /v1/payments/transfers/prepare → Sdp::PreparedTransfer
      # Builds — but does not sign or send — the transaction, for
      # non-custodial flows where the caller holds the keys.
      def prepare_transfer(source:, destination:, amount:, token: "SOL", memo: nil,
                           reference_address: nil, options: nil)
        payload = transfer_payload(source, destination, amount, token, memo)
        payload[:referenceAddress] = reference_address if reference_address
        payload[:options] = options if options
        PreparedTransfer.from_hash(post("/v1/payments/transfers/prepare", payload).data)
      end

      # GET /v1/payments/transfers → Enumerator yielding Sdp::Transfer
      #
      # Auto-paginates: without page:, the returned lazy enumerator follows
      # meta.hasMore across pages, fetching each page only when iteration
      # reaches it and re-sending the filters every time. With an explicit
      # page:, it yields exactly that page and never fetches another.
      # page_size is clamped to Pagination::MAX_PAGE_SIZE (100).
      #
      # Filters: wallet: (walletId), wallet_address:, token:, direction:
      # ("inbound"/"outbound"), status: (string or array, sent
      # comma-separated), page:, page_size:.
      def list_transfers(wallet: nil, wallet_address: nil, token: nil, direction: nil,
                         status: nil, page: nil, page_size: nil)
        query = {
          wallet: wallet,
          walletAddress: wallet_address,
          token: token,
          direction: direction,
          status: status && Array(status).join(","),
          page: page,
          pageSize: page_size
        }.compact
        Pagination.enumerate(self, "/v1/payments/transfers", query) do |response|
          rows = response.data.is_a?(Array) ? response.data : []
          rows.map { |transfer| Transfer.from_hash(transfer) }
        end
      end

      # GET /v1/payments/transfers/:id → Sdp::Transfer
      def get_transfer(transfer_id)
        response = get("/v1/payments/transfers/#{encode_path_segment(transfer_id)}")
        data = response.data
        src = data.is_a?(Hash) ? (data[:transfer] || data) : data
        Transfer.from_hash(src)
      end

      private

      def transfer_payload(source, destination, amount, token, memo)
        payload = { source: source, destination: destination, token: token, amount: amount.to_s }
        payload[:memo] = memo if memo
        payload
      end
    end
  end
end
