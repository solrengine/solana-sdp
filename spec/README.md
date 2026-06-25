# Vendored SDP OpenAPI spec

`openapi-v0.31.json` is the pinned contract for the surface this gem covers (see `Sdp::Coverage::COVERED_ENDPOINTS`).

Provenance: copied unmodified from `solana-foundation/solana-developer-platform` (via fork `moviendome/solana-developer-platform`), `apps/sdp-api/generated/openapi.json`, commit `630d6f674fe1171636eed1303ad212bd8e042757` (SDP v0.31.0), vendored 2026-06-22. `rake "sdp:drift[…]"` reported **no drift on the covered surface** versus the previous v0.28 pin — every wallets / payments / issuance endpoint and field this gem reads is unchanged across v0.28 → v0.31. The file's `info.version` reads `0.1.0` — a generator artifact, not the SDP release version. Regenerable upstream with `pnpm openapi:generate` in `apps/sdp-api`.

On an SDP version bump: re-vendor the newer spec under a new pinned name, run `rake "sdp:drift[path]"` against it first to see what changed, then update the contract tests and `Sdp::COMPATIBLE_SDP_VERSION`.
