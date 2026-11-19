# Loupe — Action bar: Info, Slideshow, Share, Favorite, Rotate (Tasks 24–26)

> **For agentic workers:** executed with superpowers:subagent-driven-development on branch `phase1`. Global Constraints from `2026-11-18-loupe-phase1.md` and the owner decisions in `2026-11-18-loupe-albums-import.md` still apply, except where this plan changes them below.

**Goal.** Add a Photos-style action group to the toolbar: **(i) Info**, **▶ Play** (slideshow), **Share**, **♡ Favorite** and **Rotate**. The buttons act on the grid selection, or on the photo the viewer is showing. The owner chose all five on 2026-11-19.

**Rotation never touches image files.** Rotate writes the standard XMP property `tiff:Orientation` (namespace `http://ns.adobe.com/tiff/1.0/`, EXIF values 1–8) into the photo's sidecar. Lightroom and darktable honour it. Whether LightCraft does is unverified, so it goes on the owner's check list.

The **effective orientation** is the sidecar's `tiff:Orientation` if present, otherwise the file's embedded EXIF orientation, otherwise 1. Every renderer uses it: grid thumbnails, viewer, slideshow and share exports.

**Global Constraints changes**
- The XMP fields Loupe owns become `xmp:Rating`, `dc:subject`, `lr:hierarchicalSubject` and **`tiff:Orientation`**.
- LightCraft does not own `tiff:Orientation`: it preserves foreign fields byte for byte (`docs/lightcraft-behavior.md`). So the stale-revert guard does not cover this field.
- Test command: `scripts/test.sh [--filter X]`. Use temp dirs only. Afterwards, `ls ~/Library/Preferences | grep -c '^loupe-'` must print 0.
- UI: SwiftUI's `@State` macro doesn't compile with the Command Line Tools. Use `State(initialValue:)` stored properties or model state instead.

---

### Task 24: Rotation without touching the file

**Files:**
- Create:
  - `Sources/LoupeCore/Models/Orientation.swift`
  - `Tests/LoupeCoreTests/OrientationTests.swift`
  - `Tests/LoupeXMPTests/OrientationXMPTests.swift`
  - `Tests/LoupeMediaTests/OrientedRenderingTests.swift`
- Modify:
  - `PhotoMetadata`/`MetadataChange` (`Sources/LoupeCore/Models/PhotoMetadata.swift`)
  - `Sources/LoupeXMP/{XMPNamespaces,XMPDocument,XMPDocument+Write}.swift`
  - `Sources/LoupeIndex/{Schema,Scanner,Library,CellInfo}.swift` (migration `v4`)
  - `Sources/LoupeMedia/{ThumbnailCache,ImageLoader,MediaInfoReader}.swift`
  - `Sources/LoupeFeatures/Share/{JPEGExporter,OriginalExporter}.swift`
  - the UI call sites that load images (grid cell loader, viewer)

**Interfaces:**
- `public struct Orientation: Hashable, Sendable { public let exif: Int }` in the range 1…8, with:
  - `static let up`
  - `func rotated(clockwise: Bool) -> Orientation`, which composes a 90° turn with the existing value and keeps any mirroring, using the EXIF D4 group table
  - `func relative(to base: Orientation) -> Orientation`, the extra transform to apply on top of an image already rendered with `base`
  - `var swapsDimensions: Bool` (true for 5–8)
  - `func apply(to image: CGImage) -> CGImage?`, a pixel transform with no file I/O
- `PhotoMetadata.orientation: Int?`: the sidecar's `tiff:Orientation`, or nil when absent.
- `MetadataChange.rotate(clockwise: Bool)`, applied as `newOrientation = (sidecar ?? embedded ?? 1).rotated(…)`.
  - Writing back the value the file already has (rotating four times returns to the embedded orientation) **removes** `tiff:Orientation` from the sidecar instead of writing a redundant value. Otherwise the result is written as an element in the first Description, or updated in place in element or attribute form, like `xmp:Rating`.
  - Rotation must never write to the image file. Assert in tests that the image's sha256 is unchanged.
- Index:
  - Migration `v4` adds `photo.orientationOverride INTEGER NULL`, filled from the sidecar by the scanner and by `Library.apply`.
  - `CellInfo` gains `orientationOverride: Int?`.
- Rendering:
  - `ThumbnailCache.thumbnail(for:kind:orientation:)`: the override is part of the cache key, so a rotated photo gets a new thumbnail.
  - `ImageLoader.image(at:maxPixelSize:orientation:)`.
  - Both decode with the embedded orientation applied (as today), then apply `override.relative(to: embedded)`.
- `MediaInfo` pixel width and height swap when the effective orientation swaps dimensions.
- Share exports:
  - JPEG presets bake the effective orientation.
  - `OriginalExporter` copies losslessly but writes the effective orientation into the output's orientation tag. For JPEG, PNG and TIFF use `CGImageDestinationCopyImageSource` with an updated orientation property. Byte-copied kinds (RAW, HEIC, video) keep the file's orientation, and the share menu shows "(rotation not applied)" for them, the same way it already shows "(location kept)".

- [ ] **Step 1: Write the failing tests.**

  ```swift
  // OrientationTests
  @Test func fourClockwiseTurnsReturnHome()   // every 1…8 → rotated ×4 == itself
  @Test func clockwiseThenCounterIsIdentity()
  @Test func knownTable()                     // 1→6→3→8→1 clockwise; 2→7→4→5→2 clockwise (mirrored kept)
  @Test func relativeComposesBack()           // for all a,b: b.relative(to: a) applied after a == b (via pixel test on a 2×1 image)
  // OrientationXMPTests
  @Test func rotateWritesTiffOrientation()    // no orientation, embedded 1 → .rotate(clockwise: true) → sidecar tiff:Orientation 6; other bytes per existing canonical comparison
  @Test func rotateBackToEmbeddedRemovesProperty() // embedded 6, rotate ×4 → no tiff:Orientation element
  @Test func attributeFormUpdatedInPlace()    // tiff:Orientation="3" attribute → rotate → attribute "8"
  @Test func readerReportsOrientation()       // fixture with tiff:Orientation 8 → metadata.orientation == 8
  @Test func imageBytesNeverChange()          // JPEG + rotate via SidecarIO/Library.apply → JPEG sha256 unchanged
  // OrientedRenderingTests
  @Test func thumbnailHonoursOverride()       // 400×300 JPEG, override 6 → thumbnail is portrait (h > w)
  @Test func overrideChangesCacheKey()
  @Test func loaderHonoursOverride()
  @Test func jpegShareBakesRotation()         // .small export of override-6 photo → portrait pixels, orientation 1
  @Test func originalShareSetsOrientationTag()// JPEG original + override 6 → output orientation 6, pixels unchanged size
  // Index (add to an existing Index test file)
  @Test func scannerAndApplyStoreOverride()   // sidecar with tiff:Orientation 6 → photo.orientationOverride 6; apply rotate → updated
  ```
- [ ] **Step 2:** Run the tests. They should FAIL.
- [ ] **Step 3: Implement** until they PASS.
- [ ] **Step 4:** Run `scripts/test.sh` (all must PASS) and `scripts/bundle.sh debug`.
- [ ] **Step 5:** Commit `feat(core): rotate photos via XMP tiff:Orientation without touching files`. Update the spec's § Data model (owned fields) and `docs/lightcraft-behavior.md`. Add an "Owner check" line: does LightCraft honour `tiff:Orientation` from the sidecar?

### Task 25: Action bar with Info, Share, Favorite and Rotate

**Files:**
- Create:
  - `Sources/LoupeUI/ActionBar.swift`
  - `Sources/LoupeUI/InfoPopover.swift`
  - `Tests/LoupeUITests/ActionBarTests.swift`
- Modify:
  - `Sources/LoupeUI/{LibraryToolbar,AppModel}.swift`
  - `Sources/LoupeUI/Viewer/{PhotoViewer,InfoPanel}.swift`

**Interfaces:**
- One toolbar item holds a single glass capsule (`ControlGroup` or `HStack` of borderless buttons) **before** the zoom slider: `info.circle`, `play.fill`, `square.and.arrow.up`, `heart`/`heart.fill`, `rotate.right`.
  - Each button has a tooltip.
  - Buttons are disabled when nothing is targeted, except Play, which then starts from the first photo of the current view.
- The **target** is:
  - while the viewer is open: the photo being viewed (its focused version for Share);
  - otherwise: the grid selection, in query order.
- **Info** opens a popover anchored to the button and showing `InfoPanel`. Factor the viewer's `InfoPanel` into a reusable view fed by a photo id; it loads off the main thread. For several photos, show "N photos" plus the shared rating/tags summary.
- **Share** shows the same entries as the context menu's Share submenu (the `registry.actions` entry with id `"share"`) as a menu from the button.
- **Favorite** shows a filled heart when every target is a favorite. Clicking sets all of them, or clears all if all were favorites, through `Library.apply` (same rule as the F key).
- **Rotate** applies `.rotate(clockwise: false)`, counter-clockwise like Photos' toolbar button, through `Library.apply`.
  - ⌥-click rotates clockwise.
  - Add the menu commands **Image ▸ Rotate Left (⌘L)** and **Rotate Right (⌘R)**. Check there is no conflict with the existing ⌥⌘L.
  - The grid cell and the viewer refresh to the new orientation.
- **Play** calls `model.startSlideshow()`, which Task 26 implements. In this task it may open the viewer on the first target, so the button works end to end before Task 26.
- `ActionBarTests` cover the pure parts:
  - target resolution (viewer vs selection; query order)
  - the favorite toggle rule
  - the enabled states

- [ ] **Step 1:** Write the failing `ActionBarTests`, implement, and get them to PASS.
- [ ] **Step 2: Implement the UI.** `scripts/test.sh` and `scripts/bundle.sh debug` must pass.
- [ ] **Step 3: Manual check (controller).** With the dev library:
  - the capsule sits left of the zoom slider
  - Info opens for a selected photo
  - Favorite fills the heart and the grid shows it
  - Rotate turns the grid thumbnail and `grep Orientation` finds it in the sidecar
  - Share shows the presets
- [ ] **Step 4:** Commit `feat(ui): Photos-style action bar (info, share, favorite, rotate)`.

### Task 26: Slideshow

**Files:**
- Create:
  - `Sources/LoupeUI/Slideshow/{SlideshowModel,SlideshowView}.swift`
  - `Tests/LoupeUITests/SlideshowModelTests.swift`
- Modify:
  - `Sources/LoupeUI/{AppModel,RootView}.swift`
  - `Sources/LoupeUI/ActionBar.swift` (Play)

**Interfaces:**
- `AppModel.startSlideshow()`:
  - Photos: the targets if two or more are selected, otherwise the whole current query in order, starting at the selected or viewed photo.
  - It opens a full-screen borderless window, or the main window's full-screen overlay, with a black background.
- **`SlideshowModel` (pure, testable):**
  - `photoIDs`, `index`, `interval` (default 3 s), `isPlaying`
  - `next()`, `previous()`, `togglePlay()`, `tick()`; tick advances and wraps to the start at the end
- **`SlideshowView`:**
  - Shows each photo with the effective orientation through `ImageLoader` (Task 24) at screen pixel size, decoded off the main thread, and prefetches the next photo.
  - Cross-fades over 0.5 s.
  - Videos play once, then the slideshow advances.
- **Keys:**
  - Space pauses or plays.
  - ←/→ step to the previous or next photo.
  - Esc ends the slideshow and selects the last shown photo in the grid.
- A small control strip (◀ ⏯ ▶, interval menu 2/3/5/10 s, ✕) appears when the mouse moves and hides after 2 s.

- [ ] **Step 1:** Write the failing `SlideshowModelTests` (advance/wrap, previous at 0 wraps to the end, pause stops tick, start index honours the selection), implement, and get them to PASS.
- [ ] **Step 2: Implement the view and the window.** `scripts/test.sh` and `scripts/bundle.sh debug` must pass.
- [ ] **Step 3: Manual check.** Owner or controller: Play starts full screen, advances, pauses on Space and exits on Esc.
- [ ] **Step 4:** Commit `feat(ui): slideshow`.
