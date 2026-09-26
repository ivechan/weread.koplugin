# v1.5.5 validation — 2026-09-26

Scope: chapter-change progress sync, cancellation/resume, and missing Web reader
session recovery. The existing less-than-3% upload threshold is unchanged.

| Check | Result | Evidence / limitation |
| --- | --- | --- |
| Lua unit/component suite | PASS | All 78 specs; smart sync includes busy chapter transitions, cancelled pulls, late responses, resume, and missing/invalid reader sessions. |
| Regression against previous implementation | PASS | New spec fails against v1.5.4 at the missing-session recovery assertion. |
| Lua static analysis | PASS | 167 files, zero warnings/errors. |
| Namespace policy | PASS | `scripts/check_lua_namespace.sh` |
| Offline mock service | PASS | Four Python tests. |
| Candidate packaging / release notes | PASS | ZIP integrity and v1.5.5 changelog extraction. |
| Real KOReader Linux offscreen smoke | PASS | Packaged candidate, isolated synthetic profile, real Client/Content/Downloader/ReaderUI, chapter EPUB page 2 and full-book download. Local evidence: `/tmp/weread-155-smoke/evidence/`. |
| Pinned PluginLoader / remote CI | PENDING | Checked by the release workflows for the pushed commit. |
| macOS C01–C20 and applicable E01–E10 window acceptance | BLOCKED | This execution environment is Linux; no macOS desktop available. Offscreen smoke is not the full UI matrix. |
| Kindle / real WeRead account sync | BLOCKED | No device or authorized real-account fixture supplied. Network sync regressions use synthetic responses. |

Published within the user's explicit fix-and-release request, with the above
environment limitations recorded; this is not a claim of full UI/device acceptance.
