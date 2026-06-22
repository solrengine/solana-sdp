# frozen_string_literal: true

module Sdp
  # The curated SDP surface this gem covers, pinned against the vendored
  # OpenAPI spec (spec/openapi-v0.31.json). Consumed by the contract tests
  # (test/sdp/contract_test.rb) and the sdp:drift rake task.
  #
  # Path templates use the {param} style of SDP's generated spec. When a
  # resource method is added or removed, this map changes in the same commit.
  module Coverage
    # method/path identify the operation; success_status is the documented
    # success response; reads maps a navigation path inside the success
    # schema to the camelCase fields our structs read at that node. A "[]"
    # segment descends into array items; the empty path is the schema root.
    Endpoint = Struct.new(:method, :path, :success_status, :reads, keyword_init: true)

    # Fields read by Sdp::Wallet.from_hash.
    WALLET_FIELDS = %w[id walletId publicKey label status provider purpose createdAt balances].freeze
    # Fields read by Sdp::Balance.from_hash. usdValue is optional upstream —
    # presence in the schema's properties is what we pin, not requiredness.
    BALANCE_FIELDS = %w[token mint amount uiAmount decimals usdValue].freeze
    # Fields read by Sdp::Transfer.from_hash.
    TRANSFER_FIELDS = %w[id direction status signature token amount source destination memo error createdAt].freeze
    # Fields read by Sdp::Token.from_hash. extensions is passed through untyped.
    TOKEN_FIELDS = %w[id projectId signingWalletId mintAddress mintAuthority freezeAuthority name symbol
                      decimals description uri imageUrl template extensions totalSupply maxSupply isMintable
                      isFreezable requiresAllowlist status deployedAt createdAt updatedAt].freeze
    # Fields read by Sdp::TokenTransaction.from_hash (the mint/burn action record).
    TOKEN_TX_FIELDS = %w[id tokenId type status signature serializedTx params slot blockTime fee error
                         createdAt updatedAt].freeze
    # The unsigned-transaction envelope shared by the .../prepare responses.
    PREPARED_TX_FIELDS = %w[serialized blockhash lastValidBlockHeight].freeze

    COVERED_ENDPOINTS = [
      # NOTE: at v0.31 the initialize 201 response has NO data envelope —
      # configId/publicKey/walletId sit at the schema root.
      Endpoint.new(method: "post", path: "/v1/wallets/initialize", success_status: "201",
                   reads: { [] => %w[configId publicKey walletId] }),
      Endpoint.new(method: "post", path: "/v1/wallets", success_status: "201",
                   reads: { %w[data wallet] => WALLET_FIELDS }),
      Endpoint.new(method: "get", path: "/v1/wallets", success_status: "200",
                   reads: { [ "data", "wallets", "[]" ] => WALLET_FIELDS }),
      Endpoint.new(method: "get", path: "/v1/payments/wallets/{walletId}/balances", success_status: "200",
                   reads: { %w[data walletBalances] => %w[walletId balances],
                            [ "data", "walletBalances", "balances", "[]" ] => BALANCE_FIELDS }),
      Endpoint.new(method: "post", path: "/v1/payments/transfers", success_status: "200",
                   reads: { %w[data transfer] => TRANSFER_FIELDS }),
      Endpoint.new(method: "post", path: "/v1/payments/transfers/prepare", success_status: "200",
                   reads: { %w[data] => %w[transfer preparedTransaction simulation],
                            %w[data transfer] => TRANSFER_FIELDS,
                            %w[data preparedTransaction] => %w[serialized blockhash lastValidBlockHeight] }),
      Endpoint.new(method: "get", path: "/v1/payments/transfers", success_status: "200",
                   reads: { [ "data", "[]" ] => TRANSFER_FIELDS }),
      Endpoint.new(method: "get", path: "/v1/payments/transfers/{transferId}", success_status: "200",
                   reads: { %w[data transfer] => TRANSFER_FIELDS }),

      # Issuance — token lifecycle + supply actions (v0.2). list returns a bare
      # data array; create/get/deploy wrap the token in data.token. mint/burn
      # return the action record at data.transaction; mint also carries
      # data.tokenAccount. The prepare variants differ: deploy/prepare puts the
      # unsigned tx at data.transaction with a sibling data.mint, while
      # mint/burn prepare keep the record at data.transaction and the unsigned
      # tx at data.preparedTransaction.
      Endpoint.new(method: "get", path: "/v1/issuance/tokens", success_status: "200",
                   reads: { [ "data", "[]" ] => TOKEN_FIELDS }),
      Endpoint.new(method: "post", path: "/v1/issuance/tokens", success_status: "201",
                   reads: { %w[data token] => TOKEN_FIELDS }),
      Endpoint.new(method: "get", path: "/v1/issuance/tokens/{tokenId}", success_status: "200",
                   reads: { %w[data token] => TOKEN_FIELDS }),
      Endpoint.new(method: "post", path: "/v1/issuance/tokens/{tokenId}/deploy", success_status: "200",
                   reads: { %w[data token] => TOKEN_FIELDS }),
      Endpoint.new(method: "post", path: "/v1/issuance/tokens/{tokenId}/deploy/prepare", success_status: "200",
                   reads: { %w[data] => %w[transaction mint simulation],
                            %w[data transaction] => PREPARED_TX_FIELDS }),
      Endpoint.new(method: "post", path: "/v1/issuance/tokens/{tokenId}/mint", success_status: "200",
                   reads: { %w[data] => %w[transaction tokenAccount],
                            %w[data transaction] => TOKEN_TX_FIELDS }),
      Endpoint.new(method: "post", path: "/v1/issuance/tokens/{tokenId}/mint/prepare", success_status: "200",
                   reads: { %w[data] => %w[transaction preparedTransaction tokenAccount simulation],
                            %w[data transaction] => TOKEN_TX_FIELDS,
                            %w[data preparedTransaction] => PREPARED_TX_FIELDS }),
      Endpoint.new(method: "post", path: "/v1/issuance/tokens/{tokenId}/burn", success_status: "200",
                   reads: { %w[data transaction] => TOKEN_TX_FIELDS }),
      Endpoint.new(method: "post", path: "/v1/issuance/tokens/{tokenId}/burn/prepare", success_status: "200",
                   reads: { %w[data] => %w[transaction preparedTransaction simulation],
                            %w[data transaction] => TOKEN_TX_FIELDS,
                            %w[data preparedTransaction] => PREPARED_TX_FIELDS })
    ].freeze

    class << self
      # The application/json schema of the endpoint's documented success
      # response, $ref-resolved. nil when the spec doesn't document it.
      def success_schema(spec, endpoint)
        operation = spec.dig("paths", endpoint.path, endpoint.method)
        schema = operation&.dig("responses", endpoint.success_status, "content", "application/json", "schema")
        resolve(spec, schema)
      end

      # Navigates a (resolved) schema along a reads path. "[]" descends into
      # array items; any other segment descends into that property. Returns
      # the resolved node, or nil as soon as the path breaks.
      def walk(spec, schema, segments)
        segments.reduce(resolve(spec, schema)) do |node, segment|
          break nil unless node

          child = segment == "[]" ? node["items"] : node.dig("properties", segment)
          resolve(spec, child)
        end
      end

      # Follows "$ref": "#/components/schemas/X" pointers (recursively, with
      # a depth guard). SDP's generated spec is fully inlined today (zero
      # $refs at v0.31) — this keeps the guard working if that changes.
      def resolve(spec, node, depth = 0)
        return node unless node.is_a?(Hash) && node["$ref"].is_a?(String)
        return nil if depth > 10

        name = node["$ref"][%r{\A#/components/schemas/(.+)\z}, 1]
        return nil unless name

        resolve(spec, spec.dig("components", "schemas", name), depth + 1)
      end
    end
  end
end
