# v1.5.7 validation — 2026-09-26

Scope: an immediately effective, persistent Settings → Progress sync
notifications checkbox. Enabled by default, including for existing profiles.
Disabling it suppresses automatic sync success/failure notices, without
disabling uploads or changing the progress comparison rule.

- PASS: all 78 Lua specs. Added coverage for default/persisted settings, menu
  toggle persistence and refresh, successful upload without notifications,
  suppressed success/HTTP-error/transport-error notices, and live re-enabling.
- PASS: Lua static analysis (167 files, zero warnings/errors), including a
  focused recheck after rearranging menu tests to preserve prior assertions.
- PASS: ZIP integrity, changelog extraction, and whitespace checks.
- PASS: real KOReader Linux offscreen smoke using the isolated candidate;
  evidence at `/tmp/weread-157-smoke/evidence/`.
- PENDING: CI, pinned PluginLoader integration, and automatic release checks
  for the pushed commit.
- BLOCKED: macOS window acceptance, Kindle hardware, and real-account sync.
  Those environments/fixtures are unavailable; synthetic and offscreen checks
  are not a full UI/device acceptance result.

Release follows the user's existing push-and-publish instruction with these
environment limitations recorded.
