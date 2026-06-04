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

## 2026-06-04

### Frontend — custom "AI thinking" loader (`lib/widgets/thinking_indicator.dart`)

- **Replaced the generic `CircularProgressIndicator`** on the capture screen
  with a bespoke, animated `ThinkingBrush` loader during scan processing
  (`lib/screens/capture_screen.dart`). _(`7870bd6`)_
- **`ThinkingBrush` — the organic "brush star".** The shipped loader: a burst
  of ~14 rays radiating from a center point, each given a deterministically
  seeded jitter (`Random(7)`) in angle, length, and stroke width so the
  silhouette reads as hand-sketched rather than mechanical. Geometry is built
  once and held stable across rebuilds; only the animation moves. Rays
  "breathe" — pulsing outward/inward and fading opacity on a soft sine, each
  with a small per-ray phase offset so the whole mark shimmers as it thinks.
  Defaults: `size 64`, `strokeWidth 3.5`, `rayCount 14`, `2400ms` loop,
  cyber-blue `#0EA5E9`. Pure presentation — no app state or data flow.
  _(`7870bd6`)_
- **`ThinkingIndicator` — sweeping-arc variant.** Also added in the same file:
  a `CustomPainter`-based rotating arc with a fading trail (cyber-blue
  default, `1600ms` loop), kept as a lighter-weight alternative. _(`7870bd6`)_
- **Throwaway preview harness** (`lib/preview_loader.dart`): a standalone
  entrypoint (`flutter run -t lib/preview_loader.dart -d chrome`) that renders
  `ThinkingBrush` at several sizes, a denser-ray variant, and on a dark
  surface — for eyeballing the loader in isolation. Touches no app logic; safe
  to delete. _(`7870bd6`)_
