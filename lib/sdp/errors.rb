# frozen_string_literal: true

module Sdp
  # Base class for every error raised by Sdp::Client.
  #
  # SDP's uniform error shape is:
  #   { "error": { "code": "...", "message": "...", "details": ... }, "meta": { ... } }
  #
  # The upstream message is preserved as the exception message; the upstream
  # code, HTTP status, details, and meta ride along for logging/branching.
  class Error < StandardError
    attr_reader :code, :http_status, :details, :meta

    def initialize(message = nil, code: nil, http_status: nil, details: nil, meta: nil)
      super(message)
      @code = code
      @http_status = http_status
      @details = details
      @meta = meta
    end
  end

  # Raised at construction/boot when SDP_API_KEY (or base URL) is unusable.
  class ConfigurationError < Error; end

  # 400 / BAD_REQUEST / VALIDATION_ERROR — the request itself is wrong.
  class BadRequest < Error; end

  # A request the configured custody provider cannot serve — not a malformed
  # request. Raised for the FL-10 gates:
  #
  # - 400 whose message matches PROVISIONING_GATE_PATTERN: local custody
  #   holds exactly one root wallet, so POST /v1/wallets is rejected.
  #   Wallet-per-User requires a managed provider (e.g. privy).
  # - 409 on POST /v1/wallets/initialize: custody is already initialized for
  #   this organization/project — initialization is one-time.
  #
  # Subclasses BadRequest so existing rescues keep working; never retryable —
  # the same request fails until the provider configuration changes.
  class ProviderCapabilityError < BadRequest
    # Verified against SDP v0.28: assertCustodyProviderCanCreateWallet
    # (apps/sdp-api/src/services/custody-provider-lifecycle.service.ts) and
    # createProviderWallet (services/domain/signing/provider-wallet-lifecycle.ts)
    # both throw:
    #   "Wallet provisioning not supported for provider: ${provider}"
    PROVISIONING_GATE_PATTERN = /Wallet provisioning not supported/i
  end

  # 502 / SOLANA_RPC_ERROR carrying the NativeAdapter signature — the FL-11
  # gate. With FEE_PAYMENT_PROVIDER=native, SDP can build and sign transfers
  # but cannot SUBMIT them; the fix is configuration (run Kora, set
  # FEE_PAYMENT_PROVIDER=kora), so retrying is pointless. A 502 that does
  # NOT match the pattern is a real upstream outage and stays Unavailable —
  # mislabeling an RPC outage as "configure Kora" would be worse than a
  # generic error.
  class TransferExecutionError < Error
    # Verified against SDP v0.28: NativeAdapter#signAndSend
    # (apps/sdp-api/src/services/adapters/fee-payment/native/native.adapter.ts)
    # throws:
    #   "NativeAdapter.signAndSend not supported - use KoraAdapter for gasless transactions"
    # (#signAsFeePayer throws the same shape with its own method name).
    NATIVE_ADAPTER_PATTERN = /NativeAdapter\.\w+ not supported - use KoraAdapter/
  end

  # 401 / UNAUTHORIZED — key missing, malformed, or revoked.
  class Unauthorized < Error; end

  # 403 / FORBIDDEN — authenticated but not allowed.
  class Forbidden < Error; end

  # 403 / INSUFFICIENT_PERMISSIONS — key lacks the required scope.
  class InsufficientPermissions < Forbidden; end

  # 404 / NOT_FOUND — wallet or transfer does not exist. Beware: wallet-scoped
  # API keys return 404 (not 403) for wallets outside their scope.
  class NotFound < Error; end

  # 409 / CONFLICT — the resource already exists or is in a conflicting state
  # (e.g. initializing a project wallet twice).
  class Conflict < Error; end

  # HTTP 202 / SIGNING_PENDING — the request was accepted but the transaction
  # is awaiting additional signatures (multisig/approval flows). NOT a
  # success: there is no data envelope, only an error-shaped body. Carries
  # code/http_status/details so callers can surface approval progress.
  class SigningPending < Error; end

  # TRANSACTION_FAILED — the on-chain transaction was attempted and failed
  # (e.g. insufficient lamports). Never blindly retried: outcome semantics
  # differ from transport errors.
  class TransactionFailed < Error; end

  # 429 / RATE_LIMITED.
  class RateLimited < Error; end

  # Net::ReadTimeout. For POSTs the outcome is UNKNOWN — callers must
  # reconcile before re-submitting (no idempotency key upstream; retrying a
  # transfer risks a double-spend).
  class Timeout < Error; end

  # Connection refused/reset, connect timeout, or a 5xx without SDP's error
  # shape. The request was never processed, so it is safe to retry.
  class Unavailable < Error; end
end
