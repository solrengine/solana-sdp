# frozen_string_literal: true

require "uri"

module Sdp
  # A token as SDP's issuance API reports it. Like every SDP resource, optional
  # fields are OMITTED (absent, not null), so each member is nil when SDP didn't
  # send it. extensions is passed through as the raw snake_cased hash — the
  # Token-2022 extension set is large and provider-shaped, so this gem surfaces
  # it untyped rather than modelling it.
  Token = Struct.new(:id, :project_id, :signing_wallet_id, :mint_address,
                     :mint_authority, :freeze_authority, :name, :symbol, :decimals,
                     :description, :uri, :image_url, :template, :extensions,
                     :total_supply, :max_supply, :mintable, :freezable,
                     :requires_allowlist, :status, :deployed_at, :created_at, :updated_at,
                     keyword_init: true) do
    def self.from_hash(hash)
      hash ||= {}
      new(
        id: hash[:id],
        project_id: hash[:project_id],
        signing_wallet_id: hash[:signing_wallet_id],
        mint_address: hash[:mint_address],
        mint_authority: hash[:mint_authority],
        freeze_authority: hash[:freeze_authority],
        name: hash[:name],
        symbol: hash[:symbol],
        decimals: hash[:decimals],
        description: hash[:description],
        uri: hash[:uri],
        image_url: hash[:image_url],
        template: hash[:template],
        extensions: hash[:extensions],
        total_supply: hash[:total_supply],
        max_supply: hash[:max_supply],
        mintable: hash[:is_mintable],
        freezable: hash[:is_freezable],
        requires_allowlist: hash[:requires_allowlist],
        status: hash[:status],
        deployed_at: hash[:deployed_at],
        created_at: hash[:created_at],
        updated_at: hash[:updated_at]
      )
    end
  end

  # An issuance transaction — the action record SDP returns for mint/burn —
  # distinct from a payments Transfer (different shape, different endpoints).
  # token_account is the associated token account SDP returns alongside a mint
  # (a sibling of the transaction in the envelope, folded in here); nil when SDP
  # didn't send one (e.g. burn).
  TokenTransaction = Struct.new(:id, :token_id, :type, :status, :signature,
                                :serialized_tx, :params, :slot, :block_time, :fee,
                                :error, :token_account, :created_at, :updated_at,
                                keyword_init: true) do
    def self.from_hash(hash, token_account: nil)
      hash ||= {}
      new(
        id: hash[:id],
        token_id: hash[:token_id],
        type: hash[:type],
        status: hash[:status],
        signature: hash[:signature],
        serialized_tx: hash[:serialized_tx],
        params: hash[:params],
        slot: hash[:slot],
        block_time: hash[:block_time],
        fee: hash[:fee],
        error: hash[:error],
        token_account: token_account,
        created_at: hash[:created_at],
        updated_at: hash[:updated_at]
      )
    end
  end

  # Result of a .../prepare issuance call: the unsigned transaction the caller
  # must sign and submit before blockhash expiry, plus context. SDP nests this
  # two different ways and from_action/from_deploy normalize both:
  #
  # - mint/burn prepare → the provisional record under :transaction, the
  #   unsigned tx under :prepared_transaction (transaction is a TokenTransaction).
  # - deploy prepare → :transaction IS the unsigned tx envelope and the new
  #   mint address rides alongside under :mint (transaction is nil — there is no
  #   action record yet).
  # The mint/burn associated token account lives on #transaction (TokenTransaction)
  # when SDP returns one; deploy carries no action record. There is deliberately
  # no top-level token_account — it would only ever duplicate transaction.token_account.
  PreparedTokenTransaction = Struct.new(:transaction, :serialized, :blockhash,
                                        :last_valid_block_height, :mint, :simulation,
                                        keyword_init: true) do
    def self.from_action(hash)
      hash ||= {}
      prepared = hash[:prepared_transaction] || {}
      new(
        transaction: TokenTransaction.from_hash(hash[:transaction], token_account: hash[:token_account]),
        serialized: prepared[:serialized],
        blockhash: prepared[:blockhash],
        last_valid_block_height: prepared[:last_valid_block_height],
        mint: nil,
        simulation: hash[:simulation]
      )
    end

    def self.from_deploy(hash)
      hash ||= {}
      tx = hash[:transaction] || {}
      new(
        transaction: nil,
        serialized: tx[:serialized],
        blockhash: tx[:blockhash],
        last_valid_block_height: tx[:last_valid_block_height],
        mint: hash[:mint],
        simulation: hash[:simulation]
      )
    end
  end

  module Resources
    # Token issuance: the core lifecycle (list / get / create / deploy) and the
    # supply actions (mint / burn), each action with a prepare variant for
    # caller-signed (non-custodial) flows. Mint/burn/deploy are money-path and
    # follow the same never-retry-on-write posture as transfers.
    #
    # Out of scope at v0.2: the compliance actions (freeze/unfreeze, pause,
    # authority, allowlist, seize, force-burn) — they roughly double the surface
    # and target stablecoin issuers, not the general dev-tool path.
    module Issuance
      # GET /v1/issuance/tokens → Enumerator yielding Sdp::Token.
      # Auto-paginates on meta.hasMore (see Pagination); re-sends filters per
      # page. Filters (camelCased on the wire): status:, page:, page_size:.
      # (SDP v0.31 documents no other query filters on this endpoint.)
      def list_tokens(status: nil, page: nil, page_size: nil)
        query = { status: status, page: page, pageSize: page_size }.compact
        Pagination.enumerate(self, "/v1/issuance/tokens", query) do |response|
          rows = response.data.is_a?(Array) ? response.data : []
          rows.map { |token| Token.from_hash(token) }
        end
      end

      # GET /v1/issuance/tokens/:id → Sdp::Token
      def get_token(token_id)
        Token.from_hash(token_node(get("/v1/issuance/tokens/#{encode_path_segment(token_id)}")))
      end

      # POST /v1/issuance/tokens → Sdp::Token.
      # Registers the token record; it is NOT on-chain until #deploy_token.
      # Never retried (write). amounts/decimals follow SDP's types; maxSupply is
      # a base-units string.
      def create_token(name:, symbol:, signing_wallet_id:, decimals: nil, max_supply: nil,
                       description: nil, uri: nil, image_url: nil, template: nil,
                       mintable: nil, freezable: nil, requires_allowlist: nil)
        payload = {
          name: name, symbol: symbol, signingWalletId: signing_wallet_id,
          decimals: decimals, maxSupply: max_supply, description: description,
          uri: uri, imageUrl: image_url, template: template,
          isMintable: mintable, isFreezable: freezable, requiresAllowlist: requires_allowlist
        }.compact
        Token.from_hash(token_node(post("/v1/issuance/tokens", payload)))
      end

      # POST /v1/issuance/tokens/:id/deploy → Sdp::Token (now on-chain).
      # Custodial sign-and-send; never retried.
      def deploy_token(token_id)
        Token.from_hash(token_node(post(deploy_path(token_id))))
      end

      # POST /v1/issuance/tokens/:id/deploy/prepare → Sdp::PreparedTokenTransaction
      # Builds — does not send — the deploy tx for caller-signed flows; the new
      # mint address is on #mint.
      def prepare_deploy(token_id)
        PreparedTokenTransaction.from_deploy(post("#{deploy_path(token_id)}/prepare").data)
      end

      # POST /v1/issuance/tokens/:id/mint → Sdp::TokenTransaction.
      # Custodial sign-and-send mint to destination; never retried. amount is a
      # base-units string. The associated token account is on #token_account.
      # (Noun-suffixed to match create_token/deploy_token and to leave room for a
      # future #freeze_token without colliding with Ruby's Object#freeze.)
      def mint_token(token_id, signing_wallet_id:, destination:, amount:, memo: nil)
        action_result(post(mint_path(token_id), mint_payload(signing_wallet_id, destination, amount, memo)))
      end

      # POST /v1/issuance/tokens/:id/mint/prepare → Sdp::PreparedTokenTransaction
      # Builds — does not sign or send — the mint tx for caller-signed flows.
      def prepare_mint(token_id, signing_wallet_id:, destination:, amount:, memo: nil)
        PreparedTokenTransaction.from_action(
          post("#{mint_path(token_id)}/prepare", mint_payload(signing_wallet_id, destination, amount, memo)).data
        )
      end

      # POST /v1/issuance/tokens/:id/burn → Sdp::TokenTransaction.
      # Custodial sign-and-send burn from source; never retried.
      def burn_token(token_id, signing_wallet_id:, source:, amount:, memo: nil)
        action_result(post(burn_path(token_id), burn_payload(signing_wallet_id, source, amount, memo)))
      end

      # POST /v1/issuance/tokens/:id/burn/prepare → Sdp::PreparedTokenTransaction
      # Builds — does not sign or send — the burn tx for caller-signed flows.
      def prepare_burn(token_id, signing_wallet_id:, source:, amount:, memo: nil)
        PreparedTokenTransaction.from_action(
          post("#{burn_path(token_id)}/prepare", burn_payload(signing_wallet_id, source, amount, memo)).data
        )
      end

      private

      # create/get/deploy wrap the token in a data.token envelope; stay tolerant
      # of a bare token (or empty body → {}) so the struct degrades to all-nil.
      def token_node(response)
        data = response.data
        data.is_a?(Hash) ? (data[:token] || data) : data
      end

      # mint/burn wrap the action record in data.transaction (mint also carries a
      # sibling data.tokenAccount). Guard the envelope to a Hash so a money-path
      # response that comes back off-shape or empty degrades to an all-nil struct
      # rather than raising a raw TypeError mid-reconcile.
      def action_result(response)
        data = response.data
        data = {} unless data.is_a?(Hash)
        TokenTransaction.from_hash(data[:transaction], token_account: data[:token_account])
      end

      def mint_payload(signing_wallet_id, destination, amount, memo)
        mint = { destination: destination, amount: amount.to_s }
        mint[:memo] = memo if memo
        { signingWalletId: signing_wallet_id, mint: mint }
      end

      def burn_payload(signing_wallet_id, source, amount, memo)
        burn = { source: source, amount: amount.to_s }
        burn[:memo] = memo if memo
        { signingWalletId: signing_wallet_id, burn: burn }
      end

      def deploy_path(token_id)
        "/v1/issuance/tokens/#{encode_path_segment(token_id)}/deploy"
      end

      def mint_path(token_id)
        "/v1/issuance/tokens/#{encode_path_segment(token_id)}/mint"
      end

      def burn_path(token_id)
        "/v1/issuance/tokens/#{encode_path_segment(token_id)}/burn"
      end

      def encode_path_segment(segment)
        URI.encode_uri_component(segment.to_s)
      end
    end
  end
end
