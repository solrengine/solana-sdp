# frozen_string_literal: true

require "uri"

module Sdp
  # Token balance row from GET /v1/payments/wallets/:id/balances.
  # amount is base units (string); ui_amount is the decimal string.
  # usd_value is passed through when SDP includes it and is nil otherwise
  # (varies across SDP versions) — nil means "no price", never zero.
  Balance = Struct.new(:token, :mint, :amount, :ui_amount, :decimals, :usd_value, keyword_init: true) do
    def self.from_hash(hash)
      hash ||= {}
      new(
        token: hash[:token],
        mint: hash[:mint],
        amount: hash[:amount],
        ui_amount: hash[:ui_amount],
        decimals: hash[:decimals],
        usd_value: hash[:usd_value]
      )
    end
  end

  # Custody wallet. #id is SDP's walletId — the identifier the payments API
  # expects — not the database row id. balances is only populated when the
  # list was fetched with include_balances: true.
  Wallet = Struct.new(:id, :public_key, :label, :status, :provider, :purpose, :created_at, :balances,
                      keyword_init: true) do
    def self.from_hash(hash)
      hash ||= {}
      new(
        id: hash[:wallet_id] || hash[:id],
        public_key: hash[:public_key],
        label: hash[:label],
        status: hash[:status],
        provider: hash[:provider],
        purpose: hash[:purpose],
        created_at: hash[:created_at],
        balances: hash[:balances]&.map { |balance| Balance.from_hash(balance) }
      )
    end
  end

  module Resources
    # Wallet endpoints: custody initialize, create, list, plus the balances
    # read (which lives under /v1/payments but is wallet-shaped).
    module Wallets
      # POST /v1/wallets/initialize — one-time project custody setup.
      # Both fields are optional; the request is sent without a body when
      # neither is given. provider falls back to the client's configured
      # custody_provider (SDP_CUSTODY_PROVIDER) when not passed. Returns the
      # snake_cased data hash exactly as SDP sent it (custody config + root
      # wallet fields incl. :public_key) — kept tolerant because the shape
      # varies by custody provider.
      def initialize_custody(provider: nil, wallet_label: nil)
        payload = { provider: provider || custody_provider, walletLabel: wallet_label }.compact
        post("/v1/wallets/initialize", payload.empty? ? nil : payload).data
      end

      # POST /v1/wallets → Sdp::Wallet. Wallet#id is SDP's walletId.
      # provider falls back to the client's configured custody_provider. A
      # managed provider (e.g. privy) is required for Wallet-per-User — local
      # custody holds a single root wallet and raises Sdp::ProviderCapabilityError.
      def create_wallet(label:, provider: nil)
        response = post("/v1/wallets", { label: label, provider: provider || custody_provider }.compact)
        data = response.data
        src = data.is_a?(Hash) ? (data[:wallet] || data) : data
        Wallet.from_hash(src)
      end

      # GET /v1/wallets → [Sdp::Wallet, ...]
      # Filters (camelCased on the wire): provider:, project_id:,
      # include_balances:. Not paginated at v0.31 — the whole list comes back
      # in one response — but routed through Pagination.enumerate so a
      # paginated upstream upgrade is a one-line change here.
      def list_wallets(provider: nil, project_id: nil, include_balances: nil)
        query = { provider: provider || custody_provider, projectId: project_id,
                  includeBalances: include_balances }.compact
        Pagination.enumerate(self, "/v1/wallets", query) do |response|
          rows =
            case response.data
            when Array then response.data
            when Hash  then response.data[:wallets] || []
            else []
            end
          rows.map { |wallet| Wallet.from_hash(wallet) }
        end.to_a
      end

      # GET /v1/payments/wallets/:id/balances → [Sdp::Balance, ...]
      # Upstream swallows RPC failures, so a token row (even SOL) may be
      # MISSING entirely — a missing row means "unavailable", never zero.
      def wallet_balances(wallet_id)
        data = get("/v1/payments/wallets/#{encode_path_segment(wallet_id)}/balances").data
        container = data.is_a?(Hash) ? (data[:wallet_balances] || data) : {}
        (container[:balances] || []).map { |balance| Balance.from_hash(balance) }
      end
    end
  end
end
