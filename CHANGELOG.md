# Changelog

Development session summaries for the Smart Expense Agent. Newest entries at
the bottom.

## 2026-06-03

### Backend — Gemini service on Vertex AI (`backend/src/services/gemini.ts`)

- **Migrated to the unified `@google/genai` SDK** in Vertex AI mode
  (`vertexai: true`), replacing the deprecated `@google-cloud/vertexai`.
  Auth is via a GCP service account (`GCP_PROJECT_ID`, `GCP_LOCATION`,
  `GCP_PRIVATE_KEY_JSON`); image payload mapping and the system prompt are
  unchanged. _(`dcf3327`)_
- **Fixed the 40s+ latency tail.** Diagnosed it as `gemini-2.5-flash`'s
  default dynamic "thinking" phase (the legacy SDK couldn't control or even
  measure it). Disabled thinking and added an explicit `responseSchema` for
  constrained decoding, plus per-scan `prompt/candidates/thoughts/total`
  token telemetry. Latency dropped to ~1.5s. _(`dcf3327`)_
- **Relaxed the schema:** removed `start_time`/`end_time` from the `required`
  array (kept as optional nullable properties + in `propertyOrdering`) so the
  model stops inventing times on timeless receipts. _(`810efe1`)_
- **Tuned the thinking budget:** `0 → 1024` (a reasoning window for parking
  entry/exit times and discount math) _(`810efe1`)_, then `1024 → 400` to
  shrink the per-request TPM footprint and stay clear of rate limits.
  _(`ae38720`)_
- **Added a defensive 429 retry** (`generateWithRetry`): on a single
  `RESOURCE_EXHAUSTED` / HTTP 429, wait 1.5s and retry exactly once before
  failing — so a transient burst limit never reaches the UI. Detected via the
  SDK's `ApiError.status` with a message-substring fallback. _(`ae38720`)_

### Frontend — receipt cards (`lib/widgets/receipt_card.dart`)

- **Defensive time-row rendering:** hide the row entirely when both
  `start_time`/`end_time` are null or blank; show a single clean time (no
  trailing `→ —`) when only one is present; full `start → end` range when
  both exist. Added a `_nonEmpty()` helper that treats `""`/whitespace like
  null. Label kept as `Time` for consistency. _(`18a029f`)_

### Explored, then rolled back

- Prototyped a `ScanUIState` state machine (`idle / processingLaser /
  showingBoundingBoxes / navigating`) with a glowing laser-scan animation and
  bounding-box overlay scaffolding in `lib/screens/capture_screen.dart`.
  Rolled back fully to the last stable `HEAD` after it introduced a UI
  regression; the file is byte-for-byte back to its pre-session state.

### Ops

- Legacy AI Studio `GEMINI_API_KEY` deleted from Render. The backend now
  authenticates to Vertex AI via the GCP service account; no API key in the
  request path.
