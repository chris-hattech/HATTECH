# Infrared Contour Stream — V & H Measurement Tools
## Porting Specification (iPad app → macOS app)

This document describes, in implementation-level detail, how the **Horizontal ("H") and
Vertical ("V") measurement tools** on the tyre infrared contour timeline are built in the
iPad app (`HATTECH_IRTBS`), so the same functionality can be rebuilt in the macOS
application. It is written to be self-contained: everything needed to reimplement the
tools is described here, with references back to the source of truth.

**Source of truth:**
`Hattech_TireMonitor/Interface/DataHandling/DataControls/ThermalContourViewController.swift`
(~7,400 lines, UIKit). Key line references are given throughout (they refer to that file
unless stated otherwise).

---

## 1. What the screen is

The Thermal Contour screen renders an entire session of infrared tyre/rotor temperature
data as one large horizontally-scrolling **heat-map image** ("contour"):

- **X axis = time.** The whole session is one wide bitmap; 1 sample column = `cellWidth`
  (2 logical pt) wide.
- **Y axis = sensor channels, grouped into stream bands.** Each IR sensor stream (LF, RF,
  LR, RR, rotors, customs) is a horizontal band of `channelCount` rows (16 or 32 channels
  across the tyre width), each row `channelHeight` (5 pt) tall. Bands are separated by
  `sensorGap` (12 pt). Temperature → colour via a blue→cyan→yellow→red→dark-red ramp
  scaled to the tyre/rotor/custom range.
- The image lives in a `UIImageView` inside a zoomable/pannable `UIScrollView`.
- A fixed **centre line + notch** overlays the middle of the viewport; whatever sample is
  under the notch drives a floating tooltip (temperature, PSI, stream name, elapsed time)
  and the measurement tool buttons.
- An optional synced **video panel** (AVPlayer) plays the session video; scrolling the
  timeline seeks the video and vice versa.

The V and H tools are **overlay views positioned in the image's logical coordinate
space** (they are subviews of the image view, so they scale/scroll with the content
automatically — see §4.4).

---

## 2. Data model the tools operate on

```swift
struct SensorFrame: Codable {            // one time sample of one stream
    let timestamp: Date
    let values: [Float]                  // one temperature per channel
}

struct SensorSeries: Codable {           // one IR stream
    let key: String                      // "LF","RF","LR","RR","TRK","LFR","RFR","LRR","RRR","CUSTOM1"...
    let shortName: String                // display code, e.g. "LF", "LFR", "IR 10"
    let channelCount: Int                // 16 or 32
    let frames: [SensorFrame]
}
```

Facts the tools rely on (lines 15–31, 260, 429–437, 2042–2078, 2629–2665):

- **Unified timeline.** After CSV/HTC parsing, every stream is linearly interpolated onto
  a single timeline: `timelineFrameCount = round(duration * fps) + 1` with `fps = 30`
  (display rate; raw capture is 10 Hz). Duration is the video duration when a session
  video exists, otherwise the data duration. After this step **all streams have the same
  frame count**, so `sampleIndex` is comparable across streams — the paired-stream
  feature of the H tool depends on this.
- **Missing data sentinel:** temperature `-9999` (`missingTemperatureSentinel`) means "no
  reading"; every min/max scan skips it. TPMS sentinel is `-1`, gyro `-9999`.
- **Channel counts:** normalised per stream to 16 or 32 (`buildOrderedSeries`, line 2640).
- **TPMS pressure:** `tpmsPSIByTyre: [String: [Float]]` — PSI per unified-timeline sample,
  keyed by tyre stream key (mapped TPMS1→LF, TPMS2→RF, TPMS3→LR, TPMS4→RR).
- **Paired stream mapping** (line 4725) — the opposite tyre/rotor on the same axle:
  `LF↔RF, LR↔RR, LFR↔RFR, LRR↔RRR` (TRK/custom streams have no pair).
- **Range groups** (line 26): keys LF/RF/LR/RR/TRK → `.tyre`, LFR/RFR/LRR/RRR → `.rotor`,
  everything else `.custom`. Used for colour scaling and labelling ("Tyre"/"Rotor").

---

## 3. Canvas geometry & coordinate mapping (critical)

All overlay math happens in the **base (unzoomed) logical image coordinate space**,
`baseImageSize`. Constants (lines 380–385):

```swift
captureFPS = 10          // raw sensor rate
fps        = 30          // unified timeline rate
cellWidth  = 2           // pt per sample column
channelHeight = 5        // pt per channel row
sensorGap  = 12          // vertical gap between stream bands
```

Vertical layout (lines 2408–2423): the image starts with a **blank band** (one stream
height) at the top, then an optional **gyro band** (`max(blankStreamHeight, 120)` pt)
with gaps, then the stream bands in `orderedKeys` order, then a trailing blank band.

Key mapping functions to port verbatim:

```swift
// top Y of stream band i (line 5163)
streamBaseY(i) = topBlankStreamVerticalOffset()
               + Σ_{j<i} (series[j].channelCount * channelHeight + sensorGap)

// X for a sample index (line 4181)
markerXPosition(s, frameCount) = (s / (frameCount - 1)) * baseImageSize.width

// sample index for an image X (line 5172)
sampleIndex(forImageX x, frameCount) =
    clamp(round((x / baseImageSize.width) * (frameCount - 1)), 0, frameCount - 1)

// timeline seconds for a sample (line 5014)
timelineSecondsForSample(s, frameCount) = (s / (frameCount - 1)) * timelineDurationSeconds

// channel row for an image Y within stream i (line 5157)
channelIndex(at: y, for: i) = floor((y - streamBaseY(i)) / channelHeight)

// centre-line Y of a channel (used everywhere an overlay sits "on" a channel)
channelCenterY = streamBaseY(i) + (channel + 0.5) * channelHeight
```

**Hit testing** — `notchSample(atImagePoint:)` (line 5092) converts an image-space point
into a `NotchSample`:

```swift
struct NotchSample {
    let streamIndex: Int      // -1 for the gyro band
    let streamKey: String     // "GYRO" for the gyro band
    let channelIndex: Int
    let sampleIndex: Int
    let temperature: Float
    let imageX: CGFloat
    let imageY: CGFloat
    let tpmsPSI: Float?
    var id: String { "\(streamKey)|\(channelIndex)|\(sampleIndex)" }
}
```

Returns `nil` outside the image, in inter-band gaps, or when the value at that cell is
the missing sentinel. This is the single entry point for the notch tooltip, hover
detection, tapping, and both measurement tools.

---

## 4. Shared interaction chrome

### 4.1 Centre notch & tooltip
- `centerLine`: fixed 2 pt white vertical line pinned to the horizontal centre of the
  viewport (safe-area top→bottom). `centerNotch`: 12×3 pt white pill at its middle.
- On every scroll/zoom tick, `notchSampleAtCurrentPosition()` (line 5087) converts the
  notch centre into image space and re-evaluates `updateNotchTemperatureTooltip()`
  (line 3990), which drives everything below.

### 4.2 The "H +" and "V +" buttons (lines 1102–1126)
- Two small pill buttons, 24 pt tall, bold 13 pt title, white text, corner radius 12,
  1 pt white(22%) border:
  - `measurementStartButton` — title **"H +"**, background RGB(0.18, 0.62, 0.95).
  - `verticalMeasurementButton` — title **"V +"**, background RGB(0.33, 0.53, 0.95).
- They sit in a row next to the notch tooltip label (tooltip → "+" marker button →
  "H +" → "V +"), anchored to the tooltip's centre-Y.
- **Visibility rule** (in `updateNotchTemperatureTooltip`): fade in (0.16 s) whenever the
  notch is over a *valid* sample; fade out when over the gyro band, over no sample,
  inside an active H-span (see §5.6), over the V-tool labels, or while a V-handle drag is
  in progress.
- A **"Clear"** button (nav bar, line 1398) clears both tools (§7).

### 4.3 Hover / marker affordance (context, not core to V/H)
Holding the notch on one sample for 1.5 s reveals a green "+" button that drops a
persistent `TemperatureMarker` (stream/channel/sample/temp, JSON-persisted per session as
`markers_<sessionStem>.json`). The same `currentHoverSample` state feeds the H/V tools:
**both tools anchor to `currentHoverSample`** — i.e. the sample that was under the notch
when the button was tapped.

### 4.4 Overlay hosting
Every measurement overlay view (lines, bullets, handles, banners, labels) is added as a
**subview of the `imageView`** (lines 1507–1536) with `translatesAutoresizingMaskIntoConstraints = true`
and frames set in base-image coordinates. Because the scroll view zooms the image view,
overlays scale and track content with zero extra math. (macOS note: an
`NSView` overlay layer inside the scroll view's document view achieves the same.)

---

## 5. The H tool — horizontal (time-axis) measurement

Measures a **time window along one channel row**, finds the hottest and the subsequent
coldest sample in that window, and mirrors the whole measurement onto the paired
(opposite-side) stream. Used to measure heat build-up/cool-down across corners, e.g.
"how long from turn-in (start) to peak temp, and from peak to cooled".

### 5.1 State

```swift
struct MeasurementSpan {
    let streamKey: String        // primary stream
    var channelIndex: Int        // row being measured (mutable via drag)
    var startSampleIndex: Int
    var endSampleIndex: Int      // may be < start; render normalises
}
var measurementSpan: MeasurementSpan?
var pairedMeasurementStreamKey: String?          // opposite stream, auto-derived
var pairedMeasurementOverrideChannelIndex: Int?  // its own channel row
var didAutoAlignMeasurementToHottest = false     // one-shot auto-align latch
```

### 5.2 Creation — `measurementStartTapped()` (line 4240)
1. Requires `currentHoverSample`.
2. `reduceZoomForMeasurementAction()` — zoom × 0.85 (line 5470), then
   `zoomToTwoStreamViewport(focusStreamIndex:)` (line 1721) — animates zoom/offset so the
   focused stream *and the next stream* exactly fill the viewport height.
3. Span = hover sample's stream/channel, `start = hover sampleIndex`,
   `end = sampleIndex(start seconds + 8.0 s)` — i.e. **default window is 8 seconds**.
4. Resets paired overrides and the auto-align latch, then auto-aligns (5.3) and renders.

### 5.3 Auto-align to hottest channel (line 4346)
Once per span creation: scan every channel × every sample inside the span range on the
primary stream, pick the channel containing the single hottest valid reading, and move
the span onto it. Do the same independently for the paired stream (its own hottest
channel). This makes the tool land on the meaningful (hottest) rib without manual work.

### 5.4 Overlay & readouts — `renderMeasurementSpanOverlay()` (line 4754)
All frames in base-image space. With `left/right` = min/max of start/end and
`y = channelCenterY(primary)`:

| Element | View | Geometry / content |
|---|---|---|
| Span line | 2 pt tall white bar | x: left→right at `y − 1` |
| Start/end bullets | 8×8 white circles, black 50% border | centred at start/end X |
| End move handle | 28 pt round button, `arrow.left.and.right` icon, dark bg | right of end bullet; pan = drag end sample (X only) |
| Channel move handle | 28 pt round button, `arrow.up.and.down` icon | left of span; pan = change `channelIndex` (Y only, clamped to the stream band) |
| Hottest tick | 2×12 white tick | at X of max-temp sample within [left,right] on the channel |
| Coldest tick | 2×12 white tick | at X of the min-temp sample **searched from the hottest sample to the right edge** (cool-down, not global min); clamped ≥ hottest + 2 pt |
| Left Δ banner | grey pill, **red** 1.5 pt border, mono 11 pt | spans left-edge→hottest tick, 20 pt tall, 30 pt above the line; text `Δ mm:ss.mmm` = time start→hottest |
| Right Δ banner | grey pill, **blue** 1.5 pt border | spans hottest→coldest tick; text `Δ mm:ss.mmm` = time hottest→coldest |
| Hot / cold temp labels | tooltip-style pills, 24 pt | above the ticks, `"%.1f°"` |
| Summary banner | grey pill pinned to the bottom of the stream band | `S mm:ss.mmm   E mm:ss.mmm   Δ mm:ss.mmm` (start, end, window length in timeline time) |

Time formatting: `mm:ss.mmm` (`formattedMinutesSecondsMilliseconds`, line 5027).

### 5.5 Paired-stream mirror (lines 4802–4922)
If the primary stream has a pair (LF↔RF etc.), the *same sample range* is rendered on the
paired band automatically: its own line/bullets (at 75% alpha), its own channel move
handle, and its own hottest/coldest ticks + Δ banners + temp labels computed **from the
paired stream's own data** on `pairedMeasurementOverrideChannelIndex`. Result: one
gesture measures both sides of the axle simultaneously for direct comparison. No pair →
paired overlay hidden.

### 5.6 Interactions & edge behaviour
- **Drag end bullet or end handle** (lines 4262, 4275): map gesture X → sample index,
  update `endSampleIndex`, re-render. Start edge is fixed (re-create to move it).
- **Drag channel handles** (lines 4288, 4306): map gesture Y → channel row within that
  band, clamped; primary handle moves the primary row, paired handle the paired row.
- **Tap on the image while both a V-span and an H-span exist** (line 4187): moves the
  H-span end to the tapped X (quick end placement).
- **Centre overlay suppression** (line 3832): while the notch is horizontally inside the
  active span on the primary *or paired* stream, the notch is hidden, the centre line
  fades to 30%, tooltip/H/V buttons hide — so the fixed centre line doesn't visually
  fight the measurement. Outside the range everything returns.
- Renders defensively: span hidden if the stream disappears; all indices clamped;
  sentinel temps skipped; if no valid sample in range, ticks/banners hide but the
  line/bullets stay.

---

## 6. The V tool — vertical (across-the-tyre) measurement

Measures the **temperature profile across the tyre width at one instant**: outer / middle
/ inner ribs plus tyre pressure, at a draggable time cursor that also scrubs the session
video. This is the classic three-point tyre-temperature reading (OUT/MID/IN).

### 6.1 State

```swift
var verticalMeasurementSpan: (streamKey: String, sampleIndex: Int)?
var verticalMeasurementManualChannelIndex: [String: Int] = [:]   // keys "top"/"mid"/"bottom"
```

### 6.2 Creation — `verticalMeasurementTapped()` (line 4626)
Same zoom choreography as the H tool (reduce ×0.85 + two-stream viewport), then the span
is simply the hover sample's `(streamKey, sampleIndex)` and the overlay renders.

### 6.3 Channel regions — `verticalMeasurementRegions` (line 4443)
The band's channels split into three regions around the centre row:

```
middle = [centre−2 ... centre+2]   (centre = (channelCount−1)/2)
top    = [0 ... middle.lower−1]    (nil if empty)
bottom = [middle.upper+1 ... last] (nil if empty)
```

For each region, the displayed channel is (line 4455):
**manual override if the user dragged that label** (clamped to the region), otherwise the
**hottest valid channel in the region at the current sample**. Fallbacks: top→region's
last row, mid→centre, bottom→region's first row.

### 6.4 IN/MID/OUT semantics — `tyreIndicator` (line 4472)
Because the camera views left and right tyres from opposite sides:

- `LF`, `LR`: top = **OUT**, middle = **MID**, bottom = **IN**
- `RF`, `RR`: top = **IN**, middle = **MID**, bottom = **OUT**
- Other streams (rotors, TRK, customs): no indicator suffix.

### 6.5 Overlay — `renderVerticalMeasurementOverlay()` (line 4510)
With `x = markerXPosition(sampleIndex)`, `topY/bottomY` = band top/bottom:

| Element | Geometry / content |
|---|---|
| Vertical line | 2 pt wide white(95%), full band height at `x` |
| Left move handle | 36 pt round button (`arrow.left.and.right.circle.fill`), vertically centred, 40 pt left of the line |
| Bottom move handle | same style, centred under the line 8 pt below the band |
| PSI label | pill under the left handle: TPMS PSI at that sample, `"%.1f PSI"` or `"--.- PSI"` |
| Top/Mid/Bottom labels | pills at `x + 8`, vertically at their channel's centre-Y; text `↕︎ • 87.3° OUT` (or `--.-°` when missing); min width 110, height 24 |

Label collision handling (lines 4587–4604): top label pushed up so it never overlaps mid,
bottom pushed down likewise, all clamped inside the band.

### 6.6 Interactions
- **Drag either handle horizontally** (`verticalMeasurementMoveHandlePanned`, line 4644):
  - On `.began`: latch the scroll offset, **disable scrolling and freeze the content
    offset** (re-asserted in `scrollViewDidScroll`, line 3763) so the drag doesn't pan
    the timeline; hide the centre line/notch/tooltip/buttons for a clean view.
  - Map gesture X → `sampleIndex`, re-render, and **seek the video player** to the
    matching video time (`syncPlayerToVerticalMeasurementSample`, line 4634 — timeline
    seconds → video seconds via the duration mapping, exact-tolerance seek).
  - On end/cancel: re-enable scrolling, restore chrome.
- **Drag a temperature label vertically** (`verticalMeasurementLabelPanned`, line 4676):
  sets the manual channel override for that region ("top"/"mid"/"bottom" identified via
  the label's accessibility identifier), clamped to the region's range.
- **Centre overlay suppression** (line 3968): while the viewport centre sits within the
  V-overlay's horizontal extent (left handle → widest label) inside that band, the notch
  chrome hides.
- Zoom or layout changes re-render the overlay (`scrollViewDidZoom`,
  `viewDidLayoutSubviews`).

---

## 7. Clear / reset — `clearMeasurementsTapped()` (line 4712)

Nav-bar "Clear" button: nils both spans, clears paired overrides, manual channel
overrides and the auto-align latch, hides both overlays, and animates back to the
**overview viewport** (fit-all zoom).

Both tools are **session-scoped, in-memory only** — unlike temperature markers they are
*not* persisted to disk.

---

## 8. Timeline ↔ video coupling (needed for full parity)

- `timelineSecondsForSample` / `sampleIndex(forTimelineSeconds:)` are the bridge between
  sample indices and wall time.
- Video mapping (lines 3699–3712): proportional `videoSeconds = progress(timeline) ×
  videoDuration` plus a manual offset (`videoTimelineOffsetSeconds`).
- Scrolling the timeline seeks the video (line 3763); playing the video scrolls the
  timeline (`syncScrollFromPlayer`, line 3714) unless the user is dragging. The V tool's
  handle drag participates in this coupling (§6.6). If the macOS app has no video panel,
  drop the seek call — everything else is independent.

---

## 9. Porting notes for macOS (AppKit / SwiftUI)

The logic is UI-framework-light; the port is mostly input-plumbing:

1. **Scroll/zoom host:** `UIScrollView` + `viewForZooming` → `NSScrollView` with
   `allowsMagnification = true` and the contour image + overlay container as the document
   view. `zoomScale` → `magnification`; content offset locking during V-drags maps to
   ignoring/counteracting scroll during the drag.
2. **Gestures:** `UIPanGestureRecognizer` on handles → `NSPanGestureRecognizer` (or
   `mouseDown/Dragged/Up` on handle views); `UITapGestureRecognizer` → `NSClickGestureRecognizer`.
3. **Hover:** the iPad app *simulates* hover by parking the centre notch over a sample
   (scroll-driven) plus a 1.5 s dwell timer. On macOS you can keep the centre-notch model
   for parity **and/or** use real `NSTrackingArea` mouse hover to set
   `currentHoverSample` directly — the downstream logic (`notchSample(atImagePoint:)`,
   button visibility, tool anchoring) is unchanged.
4. **Views:** `UILabel`/`UIButton`/`UIView` overlays → `NSTextField` (bordered pills via
   layer), `NSButton`, layer-backed `NSView`s. Keep frame-based layout in base-image
   coordinates; flip coordinates or set `isFlipped = true` on the overlay container so
   the top-down Y math ports verbatim.
5. **Video:** `AVPlayer`/`AVPlayerLayer` are identical on macOS.
6. **Keep these invariants** — they are the crux of correctness:
   - all overlay geometry computed in *base* image space, hosted in the zoomed view;
   - unified timeline (equal frame count across streams) before any tool is usable;
   - sentinel `-9999` skipped in every min/max/display path;
   - clamping of every sample/channel index at every entry point;
   - paired-stream map LF↔RF, LR↔RR, LFR↔RFR, LRR↔RRR;
   - V-tool region split (centre±2) and LF/LR vs RF/RR IN/OUT orientation.

## 10. Acceptance checklist

- [ ] Hovering/parking on a valid IR sample shows the tooltip and the "H +" / "V +" buttons; gyro band and empty cells never do.
- [ ] "H +" creates an 8 s span at the anchor sample, auto-snapped to the hottest channel, zoomed to the two-stream viewport.
- [ ] H overlay shows line, bullets, draggable end handle (time) and channel handles (row), hottest/coldest ticks with temp pills, red start→hot and blue hot→cold Δ banners, and the S/E/Δ summary banner.
- [ ] Paired stream mirrors the span with independent hottest-channel selection and its own readouts; streams without a pair show primary only.
- [ ] Coldest is searched only *after* the hottest sample (cool-down), never before.
- [ ] "V +" creates a full-band vertical cursor with top/mid/bottom temp pills (correct IN/MID/OUT per side), PSI pill, and two drag handles.
- [ ] Dragging V handles scrubs time, locks timeline panning, and seeks the video; dragging a pill vertically overrides that region's channel within its clamp range.
- [ ] Missing data renders as `--.-°` / `--.- PSI`; no crashes at session edges (index clamping).
- [ ] "Clear" removes both tools and returns to the overview zoom.
- [ ] All overlays track content precisely under any zoom level and scroll position.
