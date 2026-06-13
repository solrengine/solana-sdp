# solana-sdp

Ruby SDK for the [Solana Developer Platform](https://github.com/solana-foundation/solana-developer-platform) (SDP) wallets and payments API.

Plain Ruby, zero runtime dependencies (`Net::HTTP`), typed rescuable errors that mirror SDP's real failure modes, and a retry posture that never re-sends a transfer.

> SDP is pre-mainnet, unaudited, and devnet-oriented — so is this gem. Tested against SDP **v0.28** (see [Version pin](#version-pin) below).

## Install

Add to your Gemfile:

```ruby
gem "solana-sdp"
```

Or install directly:

```sh
gem install solana-sdp
```

Requires Ruby >= 3.2.

## Quickstart

Point the client at a running SDP instance (local default: `http://127.0.0.1:8787`) with an API key:

```ruby
require "solana-sdp"

# Reads SDP_API_BASE_URL / SDP_API_KEY from ENV, or pass them explicitly.
client = Sdp::Client.new(api_key: "sk_...")

# One-time custody setup for the project (provider defaults to SDP's
# configured custody provider; pass provider: "privy" etc. for managed custody).
client.initialize_custody

# Create a wallet (requires a managed custody provider — see
# Sdp::ProviderCapabilityError below for what happens on local custody).
wallet = client.create_wallet(label: "user-42")
wallet.id         # => "wal_..."  (SDP's walletId — what the payments API expects)
wallet.public_key # => "8x3f..."

# Check balances. A missing token row means "unavailable", never zero —
# SDP swallows RPC failures upstream.
client.wallet_balances(wallet.id).each do |balance|
  puts "#{balance.token}: #{balance.ui_amount} (#{balance.usd_value || "no price"})"
end

# Send a transfer (synchronous sign-and-send; SDP confirms before responding).
transfer = client.create_transfer(
  source: wallet.id,
  destination: "Fg6PaFpoGXkYsidMpWTK6W2BeZ7FEfcYkg476zPFsLnS",
  amount: "0.05",
  token: "SOL"
)
transfer.status    # => "confirmed"
transfer.signature # => on-chain signature

# List transfers — returns a lazy enumerator that auto-paginates by
# following meta.hasMore. Pass page: to pin a single page instead.
client.list_transfers(wallet: wallet.id, direction: "outbound").each do |t|
  puts "#{t.created_at} #{t.amount} #{t.token} -> #{t.destination} [#{t.status}]"
end
```

Also available: `prepare_transfer` (build but don't sign/send, for non-custodial flows), `get_transfer`, `list_wallets`.

`list_wallets` returns an **Array** (`[Sdp::Wallet, ...]`) today — SDP does not paginate `/v1/wallets` at v0.28, so the result is fetched eagerly. When SDP adds pagination this will become a lazy Enumerator (matching `list_transfers`). Use Enumerable methods (`.find`, `.each`, `.map`) rather than array indexing or `.length` to stay forward-compatible.

## Error taxonomy

Everything raised by this gem subclasses `Sdp::Error`, which carries `#code`, `#http_status`, `#details`, and `#meta` alongside the message. Both `#details` and `#meta` are Hashes with **snake_case symbol keys** — SDP's camelCase JSON is converted to Ruby style throughout (e.g. `error.details[:field_errors]`, not `"fieldErrors"` or `:fieldErrors`). The taxonomy mirrors how SDP actually fails:

| Class | Raised when | Retryable? |
|---|---|---|
| `Sdp::ConfigurationError` | At construction: `SDP_API_KEY` missing/blank | No — fix config |
| `Sdp::BadRequest` | 400 — the request itself is wrong (validation errors) | No |
| `Sdp::ProviderCapabilityError` (< `BadRequest`) | The configured custody provider cannot serve the request: 400 wallet-provisioning gate, or 409 on a second `initialize_custody` | No — change provider config |
| `Sdp::Unauthorized` | 401 — key missing, malformed, or revoked | No |
| `Sdp::Forbidden` | 403 | No |
| `Sdp::InsufficientPermissions` (< `Forbidden`) | 403 with `INSUFFICIENT_PERMISSIONS` — key lacks the required scope | No |
| `Sdp::NotFound` | 404 — but see the [wallet-scoped key note](#the-wallet-scoped-404) | No |
| `Sdp::Conflict` | 409 — resource already exists / conflicting state | No |
| `Sdp::SigningPending` | HTTP 202 — accepted, awaiting additional signatures (multisig/approval flows). **Not a success** | No — poll/approve |
| `Sdp::TransactionFailed` | `TRANSACTION_FAILED` — the on-chain transaction was attempted and failed (e.g. insufficient lamports) | **Never** — outcome semantics, not transport |
| `Sdp::RateLimited` | 429 | Yes, with backoff |
| `Sdp::Timeout` | Read timeout — for POSTs the outcome is **unknown** | Reads yes; writes: reconcile first |
| `Sdp::Unavailable` | Connection refused/reset, connect timeout, or a 5xx that isn't a recognized capability gate | Yes — the request wasn't processed |
| `Sdp::TransferExecutionError` (< `Sdp::Error`) | 502 `SOLANA_RPC_ERROR` carrying SDP's NativeAdapter signature — the fee-payment provider cannot submit transactions. **Not caught by `rescue Sdp::Unavailable`** — it is not a transient error | No — configuration fix |

Two of these encode SDP capability gates that otherwise surface as cryptic generic errors (discriminator strings verified against SDP v0.28, documented in `lib/sdp/errors.rb`):

- **`Sdp::ProviderCapabilityError`** — with local custody, SDP holds a single root wallet and `POST /v1/wallets` is rejected ("Wallet provisioning not supported for provider: local"). Wallet-per-User requires a managed provider (e.g. privy): pass `provider:` to `create_wallet` or set `SDP_CUSTODY_PROVIDER`. Also raised when `initialize_custody` is called twice for the same org+project (409) — initialization is one-time.
- **`Sdp::TransferExecutionError`** — with `FEE_PAYMENT_PROVIDER=native`, SDP can build and sign transfers but cannot submit them; the 502 message contains the `NativeAdapter` signature. Fix: run Kora and set `FEE_PAYMENT_PROVIDER=kora`. A 502 that does *not* match this signature stays `Sdp::Unavailable` — a real RPC outage is never mislabeled as a configuration problem.

## Retry posture

- **GETs retry exactly once** on `Sdp::Timeout` / `Sdp::Unavailable` (transport-level failures), then raise.
- **POSTs never retry.** SDP has no idempotency key at v0.28: re-sending a transfer after a read timeout risks a double-spend, because the first attempt may have landed on-chain. On `Sdp::Timeout` from a write, reconcile first (e.g. `list_transfers` filtered by wallet, or match a memo) before re-submitting.
- `Sdp::TransactionFailed` is never retried blindly — it reports an on-chain outcome, not a transport failure.
- `Sdp::Unavailable` means the request was not processed (connection never opened, or a 5xx without SDP's error envelope), so it is safe to retry — with backoff for `Sdp::RateLimited`.

### The wallet-scoped 404

Wallet-scoped API keys return **404 (not 403)** for wallets outside their scope. "Not found" can therefore mean "not yours". Every `Sdp::NotFound` message carries this hint so the failure is diagnosable from logs.

## Version pin

```ruby
Sdp::COMPATIBLE_SDP_VERSION # => "0.28"
```

SDP breaks its API between minor versions. Every release of this gem names the SDP version it was tested against, both here and in the `Sdp::COMPATIBLE_SDP_VERSION` constant. The covered API surface is pinned to a vendored copy of SDP's OpenAPI spec (`spec/openapi-v0.28.json`); contract tests assert every field this gem reads exists in that spec, and `rake "sdp:drift[path/to/newer/openapi.json]"` diffs a newer SDP spec against the pin to report exactly which covered endpoints changed. On an SDP version bump: re-vendor the spec, re-run the contract tests, update `COMPATIBLE_SDP_VERSION`.

Running against a different SDP version may work, but field shapes (e.g. `usdValue` on balances) are known to change between minors.

## Scope

This gem covers SDP's wallets and payments surface: custody initialization, wallet provisioning and listing, balances, and transfers (create/prepare/list/get). Ramps, issuance, and the dashboard APIs are out of scope.

A Rails engine builds on this client — Wallet-per-User provisioning, transfer persistence, and realtime balance updates — as [solrengine-sdp](https://github.com/solrengine/solrengine-sdp).

## See also

- [solrengine-sdp](https://github.com/solrengine/solrengine-sdp) — the Rails engine on top of this client: Wallet-per-User provisioning, tracked transfers, live balance updates.
- [solrengine.org](https://solrengine.org) — the SolRengine family: the connect-your-wallet stack, and how both custody models compose.
- [Solana Developer Platform](https://github.com/solana-foundation/solana-developer-platform) — the SDP itself: the wallets + payments API this gem covers.

## Development

```sh
bundle install
bundle exec rake test     # minitest + WebMock, no network
bundle exec rubocop
```

## License

MIT. See [LICENSE.txt](LICENSE.txt).
