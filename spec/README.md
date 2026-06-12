# Vendored SDP OpenAPI spec

`openapi-v0.28.json` is the pinned contract for the surface this gem covers (see `Sdp::Coverage::COVERED_ENDPOINTS`).

Provenance: copied unmodified from `solana-foundation/solana-developer-platform` (via fork `moviendome/solana-developer-platform`), `apps/sdp-api/generated/openapi.json`, branch `fix/local-seed-flow`, commit `f4ac6a4ef3ad03990823850b74e1f832ddf115fd`, vendored 2026-06-12. That checkout matches SDP v0.28 for the covered wallets/payments surface (ramps endpoints differ from v0.28.0 but are not covered). The file's `info.version` reads `0.1.0` — a generator artifact, not the SDP release version. Regenerable upstream with `pnpm openapi:generate` in `apps/sdp-api`.

On an SDP version bump: re-vendor the newer spec under a new pinned name, run `rake "sdp:drift[path]"` against it first to see what changed, then update the contract tests and `Sdp::COMPATIBLE_SDP_VERSION`.
