# v1.5.6 validation — 2026-09-26

User-requested change: smart sync uploads the local reading position whenever
the absolute progress difference is less than 3%, including when local progress
is behind or equal. Chapter-change and periodic sync share this rule.

- PASS: all 78 Lua specs, including a chapter event with local progress behind
  the server, equal percentages, and the strict 3% boundary in both directions.
- PASS: Lua static analysis, 167 files with zero warnings/errors.
- PASS: release ZIP integrity, changelog extraction, and whitespace checks.
- PASS: real KOReader Linux offscreen smoke with the isolated v1.5.6 candidate;
  evidence at `/tmp/weread-156-smoke/evidence/`.
- PENDING: remote CI, pinned PluginLoader integration, and automatic release
  checks run for the pushed commit.
- BLOCKED: full macOS window acceptance, Kindle hardware, and real-account
  WeRead sync; this Linux environment has no suitable desktop/device/account
  fixture. Synthetic and offscreen tests do not establish those results.

Release follows the user's existing push-and-publish instruction with these
environment limitations recorded.
