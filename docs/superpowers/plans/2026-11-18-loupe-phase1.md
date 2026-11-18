# Loupe — Step 0 + Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A native macOS app that browses the photo folders in `~/Pictures` with a Photos-like UI:
- groups RAW, JPEG, Live video and edits into one photo
- opens files in LightCraft or any other editor
- shares compressed copies
- organises with folders, albums and tags stored in XMP sidecars plus Finder tags
- runs script actions

It also includes a rehearsed `osxphotos` migration out of Apple Photos.

**Architecture:** The project is a SwiftPM package with no Xcode project.
- Pure-logic library targets: `LoupeCore`, `LoupeXMP`, `LoupeMedia`, `LoupeIndex`, `LoupeFeatures`. These are unit-tested with Swift Testing.
- A `LoupeUI` target: SwiftUI plus an AppKit `NSCollectionView` grid.
- A thin `Loupe` executable, bundled into `build/Loupe.app` by a script.

Files on disk and XMP sidecars are the source of truth. The GRDB/SQLite index and the thumbnail cache are disposable. Features plug into small extension points collected in a `FeatureRegistry`.

**Tech Stack:**
- Swift 6.4 from the Command Line Tools: host macOS 27.3, deployment target macOS 15
- SwiftUI, AppKit, AVKit
- ImageIO, AVFoundation, Foundation `XMLDocument`, FSEvents
- GRDB.swift 7
- Swift Testing
- `osxphotos` via Homebrew, for the migration

**Spec:** `/Users/vitjasek/Github/loupe/docs/superpowers/specs/2026-11-18-loupe-design.md`

---

## Context

The owner likes how Apple Photos looks but not how it works: it hides originals, RAW files are hard to get out, organising is weak, and edits happen in LightCraft. The approved design (spec above) replaces Photos with a folder-based browser.

This plan covers:
- **Step 0:** the migration out of Photos.
- **Phase 1:** the core browser.

Phases 2–5 each get their own plan later: SD card import, faces, LightCraft edit rendering, and the server.

### Facts found while planning (read-only checks on this Mac)

**Toolchain**
- Xcode is not installed, only the Command Line Tools: Swift 6.4.2, macOS 27.2 SDK.
- The CLT ship `Testing.framework` and the `Observation` and `Testing` macro plugins. XCTest is not included, and neither are the SwiftUI `#Preview`/`@Entry` macros.
- Free disk space is 86 GB.

**Current contents of `~/Pictures`**
- Loose photos.
- `Photos iceland/`: CR2+JPG pairs, plus subfolders.
- `Screan shots:recording/`: PNG screenshots and `.mov` videos. The `:` shows as `/` in Finder.
- LightCraft sidecars `eby.xmp` and `IMG_2174.xmp`.
- `LightCraft Library/`: LightCraft's catalog and thumbnails. It is a plain folder, so it must be excluded explicitly.
- `LightCraft Exports/`.
- `Photos Library.photoslibrary` and `Photo Booth Library`. Both are packages.

**LightCraft 0.21.1** (`ai.storyteller.lightcraft`, `/Applications/LightCraft.app`)
- It is catalog-based and writes the sidecar as `<stem>.xmp`.
- Edits are stored as **JSON inside `<lc:settings>`** (namespace `http://ns.lightcraft.app/lc/1.0/`), not as Camera Raw `crs:` fields.
- It writes `xmp:Rating` itself, in element form.
- One of its files has **two `rdf:Description` blocks**.
- Its preferences: `xmp.autoWrite: false`, and exports go to `~/Pictures/LightCraft Exports` named `{name}`.

**Photos library**
- 73 GB in total, of which 68 GB are originals stored locally.
- `osxphotos` copies files with `NSFileManager.copyItemAtPath`. On the same APFS volume that makes clones, so exporting into `~/Pictures` should need little extra space. Task 3 measures this before the full run.
- `osxphotos` XMP sidecars contain:
  - `dc:subject`
  - `xmp:Rating`, only when one is set
  - `Iptc4xmpExt:PersonInImage`
  - `mwg-rs` face regions

  They contain no `lr:hierarchicalSubject`.
- Edited files are named `<name>_edited.jpeg` by default.

### Calls made while planning (the owner should check these)

1. **Build with SwiftPM and the Command Line Tools only.** No Xcode: it saves 10+ GB on a nearly full disk, and agents work better without `.pbxproj` files. Instruments profiling would need Xcode later.
2. **Videos are in Phase 1.** They show in the grid with a duration badge and play in the viewer. A Live Photo `.mov` groups with its still as a **LIVE** version.
3. **People names stay in XMP during migration**, as face regions and `PersonInImage`. Phase 3 uses them. They are not added as keywords, which would flood Tags. The spec said keywords; it gets updated in Task 1.
4. **The "edited" badge** means the sidecar has a non-empty `lc:settings` element.
5. **The LightCraft guard** is the spec's "vanished fields" rule, generalised to *stale-revert* (Task 12). It only runs if Task 2 shows it's needed.
6. **Development never touches the real `~/Pictures` until Task 21.** All runs use `dev-library/`, which holds APFS clones of sample photos and so costs zero extra space.
7. **Album format.** An album is written as `Albums|<name>` into both `lr:hierarchicalSubject` and `dc:subject`, and read from either. Album names that are empty or `_` are ignored, because `osxphotos` placeholders can produce them.

## Global Constraints

- Deployment target is macOS 15: `platforms: [.macOS(.v15)]`, `swift-tools-version: 6.0`.
- Build only with `swift build`/`swift test` from the CLT.
  - Never use `xcodebuild`, asset catalogs, `#Preview` or `@Entry`.
  - Tests use Swift Testing (`import Testing`). XCTest is unavailable.
- The only third-party dependency is `.package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0")`.
- Language mode: Swift 6 in every target except `LoupeUI` and `Loupe`, which use `.swiftLanguageMode(.v5)`.
- **Never change the bytes of image or video files.** Allowed writes are:
  - `.xmp` sidecars
  - Finder-tag extended attributes
  - moving, renaming and trashing whole photo groups
  - `<root>/.loupe/albums.json`
- XMP fields Loupe owns: `xmp:Rating`, `dc:subject`, `lr:hierarchicalSubject`. Everything else is preserved. Phase 1 does not write `mwg-rs`.
- Namespaces:

  | Prefix | URI |
  |---|---|
  | `x` | `adobe:ns:meta/` |
  | `rdf` | `http://www.w3.org/1999/02/22-rdf-syntax-ns#` |
  | `xmp` | `http://ns.adobe.com/xap/1.0/` |
  | `dc` | `http://purl.org/dc/elements/1.1/` |
  | `lr` | `http://ns.adobe.com/lightroom/1.0/` |
  | `lc` | `http://ns.lightcraft.app/lc/1.0/` |

- Sidecar name is `<stem>.xmp`. Darktable-style `<file>.<ext>.xmp` is read only.
- Keyword formats:
  - album: `Albums|<name>`
  - favorite: `Favorite`
  - Finder rating tag: `★<n>`, using U+2605
- Default edit markers: `["-", "_edited", " (edited"]`. Default excluded folder names: `["LightCraft Library"]`. Hidden files and packages are always skipped.
- Share presets:
  - **Original**
  - **High Quality:** full-size JPEG at quality 0.85
  - **Small:** JPEG with a 2048 px long edge at quality 0.80

  "Remove location" defaults to on.
- Paths:
  - Index: `~/Library/Application Support/Loupe/index-<first 12 hex of sha256(rootPath)>.sqlite`
  - Thumbnails: `~/Library/Caches/Loupe/thumbs/`
  - Scripts: `~/Library/Application Support/Loupe/Scripts/`
  - Albums: `<root>/.loupe/albums.json`
  - Share temp files: `$TMPDIR/Loupe-Share/`
- Bundle id: `local.loupe.Loupe`. The dev root is set with the launch argument `-LoupeRoot <path>`, read from the `UserDefaults` argument domain.

## Review Focus

These are the five inputs most likely to break things for a real user. Each one has a test in the task that owns the code.

1. **Sidecars Loupe didn't write.** Examples:
   - LightCraft's two `rdf:Description` blocks
   - `xmp:Rating="3"` in attribute form
   - unusual prefixes such as `xap:`
   - `rdf:Seq` instead of `rdf:Bag`
   - `osxphotos` placeholders `Albums|_`
   - malformed XML

   Expected: they are read correctly, and a malformed file is never overwritten. Tests in Tasks 5 and 6.
2. **Loupe, LightCraft and Finder all writing the same photo.**
   - Loupe's own writes must not ping-pong through the watcher or the Finder-tag sync.
   - An external rewrite gets reloaded.

   Tests in Tasks 10, 11 and 12.
3. **Real-world file names:**
   - NFD vs NFC (`Žluť`)
   - mixed case (`IMG_1.CR2` + `img_1.jpg`)
   - `:` in folder names
   - spaces and parentheses
   - `(n)` collision names

   Tests in Tasks 4, 8 and 13.
4. **Unreadable media:** 0-byte JPEGs, junk `.mov` files, and RAW from unsupported cameras get a placeholder. They are still indexed, with no crash and no aborted scan. Tests in Tasks 7 and 8.
5. **Files vanishing mid-operation**, for example moved in Finder or deleted.
   - Moves and trashes are all-or-nothing per photo.
   - Errors are reported per photo.
   - The index heals on the next event.

   Tests in Tasks 10 and 13.

## File Structure

```
~/Github/loupe/
  Package.swift
  Resources/Info.plist
  scripts/bundle.sh  run-dev.sh  make-dev-library.sh  make-perf-library.sh
  migration/export-from-photos.sh  migration/README.md
  docs/superpowers/{specs,plans}/…   docs/lightcraft-behavior.md   docs/phase1-verification.md
  Sources/
    LoupeCore/      Models/ (VersionKind, MediaFile, PhotoGroup, PhotoMetadata, PhotoRecord, VersionRecord,
                    LibrarySettings, PhotoQuery)  Grouping/ (MediaClassifier, PhotoGrouper)
                    Extensions/ (StorageLocation, MetadataStore, PhotoAction, ShareExporter)
    LoupeXMP/       XMPNamespaces, XMPDocument(+Write), SidecarIO, EmbeddedMetadataReader, StaleRevertGuard
    LoupeMedia/     MediaInfo(Reader), ThumbnailCache, ImageLoader, ExifSummary
    LoupeIndex/     Schema, LibraryIndex, Scanner, PhotoQueries, AlbumCatalog, FolderWatcher, Library,
                    FileOperations, Extensions/ (FeatureRegistry, LoupeFeature, SidebarSection)
    LoupeFeatures/  FinderTags/  EditIn/  Share/  Scripts/  Sidebar/  BuiltInFeatures.swift
    LoupeUI/        AppModel, RootView, SidebarView, LibraryToolbar, SettingsView, ActivityLogView, KeyCommand,
                    Grid/, Viewer/, Organize/
    Loupe/          LoupeApp.swift (@main, wiring only)
    LoupeTestSupport/ TestImages.swift, TestLibrary.swift
  Tests/ LoupeCoreTests/ LoupeXMPTests/(Fixtures/) LoupeMediaTests/ LoupeIndexTests/ LoupeFeaturesTests/ LoupeUITests/
```

**Target dependency graph.** Each task that introduces a target adds it to `Package.swift` in this shape:
- `LoupeXMP` and `LoupeMedia` depend on `LoupeCore`.
- `LoupeIndex` depends on `LoupeCore`, `LoupeXMP`, `LoupeMedia` and `GRDB`.
- `LoupeFeatures` depends on all four of those targets.
- `LoupeUI` depends on all of the above.
- `Loupe` depends on `LoupeUI`.
- `LoupeTestSupport` depends on `LoupeCore`.
- Every test target depends on its own target plus `LoupeTestSupport`.
- `LoupeXMPTests` declares `resources: [.copy("Fixtures")]`.

Test commands are `swift test --filter <SuiteName>` and, for everything, `swift test`.

---

### Task 1: Repository, package skeleton, app bundle, dev library

**Files:**
- Create: `Package.swift`, `Sources/LoupeCore/LoupeCore.swift`, `Sources/Loupe/LoupeApp.swift`, `Tests/LoupeCoreTests/SmokeTests.swift`, `Resources/Info.plist`, `scripts/bundle.sh`, `scripts/run-dev.sh`, `scripts/make-dev-library.sh`, `.gitignore`, `docs/superpowers/plans/2026-11-18-loupe-phase1.md` (a copy of this plan)
- Modify: the spec (Step 2)

**Interfaces:**
- Produces: `LoupeCore.version == "0.1.0"`; `scripts/run-dev.sh` launches the app with `-LoupeRoot "$PWD/dev-library"`.

- [ ] **Step 1:** In `~/Github/loupe`, run `git init`. Add a `.gitignore` containing `.build/`, `build/` and `dev-library/`. Copy this plan to `docs/superpowers/plans/2026-11-18-loupe-phase1.md`.
- [ ] **Step 2: Update the spec with the planning facts.** In "Sharing the sidecar with Lightcraft":
  - Replace the `crs:` guess with the LightCraft facts from Context: `lc:settings` JSON, LightCraft writes `xmp:Rating`, it's catalog-based, `autoWrite` is off, and exports go to a separate folder.
  - Edited badge rule: a non-empty `lc:settings`.
  - Phase 4 renders `lc:settings`.

  Also:
  - Conflicts: refer to the stale-revert rule (Task 12).
  - Migration: people stay as `mwg-rs` regions plus `PersonInImage`, not keywords. The edited suffix is `-edited`.
  - Constraints: SwiftPM + CLT; Phase 1 shows and plays videos.
- [ ] **Step 3: Write the failing smoke test.** `@Test func packageHasVersion() { #expect(LoupeCore.version == "0.1.0") }`
- [ ] **Step 4:** Run `swift test --filter SmokeTests`. Expected: FAIL, "cannot find 'LoupeCore' in scope", until `Package.swift` and `LoupeCore.swift` exist.
- [ ] **Step 5: Implement.**
  - `Package.swift`: targets `LoupeCore`, `Loupe` (executable) and `LoupeCoreTests`. GRDB is added in Task 8, when `LoupeIndex` first uses it.
  - `public enum LoupeCore { public static let version = "0.1.0" }`
  - `@main struct LoupeApp: App` with a single `WindowGroup` showing "Loupe", minimum size 900×600.
- [ ] **Step 6:** Run `swift test`. Expected: PASS.
- [ ] **Step 7: Bundling.**
  - `Resources/Info.plist`: `CFBundleIdentifier local.loupe.Loupe`, `CFBundleName`/`CFBundleExecutable` `Loupe`, `CFBundlePackageType APPL`, `LSMinimumSystemVersion 15.0`, `CFBundleShortVersionString 0.1.0`, `NSHighResolutionCapable true`, `NSPrincipalClass NSApplication`.
  - `scripts/bundle.sh [debug|release]`:
    1. `swift build -c <conf> --product Loupe`
    2. Assemble `build/Loupe.app/Contents/{MacOS,Resources}` and copy the binary and `Info.plist`.
    3. `codesign --force --sign - build/Loupe.app`
  - `scripts/run-dev.sh`: runs `bundle.sh debug`, then `open build/Loupe.app --args -LoupeRoot "$PWD/dev-library"`.
- [ ] **Step 8:** Run `scripts/run-dev.sh`. Expected: a window titled Loupe appears.
- [ ] **Step 9: `scripts/make-dev-library.sh`.** It APFS-clones (`cp -c -R`) samples into `dev-library/`, and refuses to run if `dev-library/` exists unless given `--force`, which deletes only `dev-library/`.

  Clones from `~/Pictures`:
  - `Photos iceland/`
  - `Screan shots:recording/`
  - `eby.jpg`, `eby.xmp`, `IMG_2174.CR2`, `IMG_2174.xmp`, `kocka1.jpg`, `memoji.jpg`

  Synthetic cases:
  - `Photos iceland/IMG_9744-edited.jpg`, a clone of `IMG_9744.JPG`
  - `broken.jpg`, 0 bytes
  - `Test.photoslibrary/x.jpg`, a package that must be skipped
  - `LightCraft Library/thumbs/t.jpg`, in the excluded folder
  - an NFD-named clone of `kocka2.jpg` named "Žluťoučký": `$(printf 'Z\xcc\x8clut\xcc\x8couc\xcc\x8cky\xcc\x81.JPG')`
- [ ] **Step 10:** Run `scripts/make-dev-library.sh`, then `du -sh dev-library` and `df -h ~`. Expected: free space is unchanged within a few MB, because the files are clones.
- [ ] **Step 11: Commit.** `git add -A && git commit -m "chore: package skeleton, bundling, dev library, spec updates"`

### Task 2: LightCraft behaviour probe (owner checkpoint, about 10 minutes)

**Files:**
- Create: `docs/lightcraft-behavior.md`, `docs/lightcraft-probe/{before,after-edit,after-second-edit}.xmp`

**Interfaces:**
- Produces: a written decision on whether Task 12 is needed, and the LightCraft export settings the owner chose.

- [ ] **Step 1 (executor): set up the probe.**
  1. `mkdir ~/Pictures/_loupe-lc-probe`, then `cp -c ~/Pictures/IMG_2174.CR2 ~/Pictures/_loupe-lc-probe/`
  2. Write `~/Pictures/_loupe-lc-probe/IMG_2174.xmp` as a copy of `~/Pictures/IMG_2174.xmp` with these changes in the second `rdf:Description`:
     - `<xmp:Rating>4</xmp:Rating>`
     - `<dc:subject><rdf:Bag><rdf:li>loupe-probe</rdf:li><rdf:li>Albums|Loupe Probe</rdf:li></rdf:Bag></dc:subject>`
     - `<lr:hierarchicalSubject><rdf:Bag><rdf:li>Albums|Loupe Probe</rdf:li></rdf:Bag></lr:hierarchicalSubject>`
  3. Save a copy as `docs/lightcraft-probe/before.xmp`.
- [ ] **Step 2 (owner, in LightCraft):**
  1. Turn on automatic XMP writing (prefs key `xmp.autoWrite`).
  2. Run `! open -a LightCraft ~/Pictures/_loupe-lc-probe/IMG_2174.CR2` and note what happens: does it import, open in the editor, or nothing?
  3. Note whether LightCraft shows rating 4 and the keyword `loupe-probe`.
  4. Change the exposure and wait for the save.
- [ ] **Step 3 (executor):** Copy the sidecar to `after-edit.xmp`. Run `diff before.xmp after-edit.xmp`. Record whether each of these survived: rating 4, `dc:subject`, `lr:hierarchicalSubject`, and the Description structure.
- [ ] **Step 4:** The executor sets `<xmp:Rating>2</xmp:Rating>` in the probe sidecar, simulating Loupe. The owner makes one more exposure change in LightCraft. The executor saves `after-second-edit.xmp` and records the rating: does it stay 2, or revert to 4 or 0 (stale catalog)?
- [ ] **Step 5 (owner):** In LightCraft's export dialog, choose "same folder as original", if it exists, with the filename `{name}-edited`. Export the probe once. The executor records the resulting path and name.
- [ ] **Step 6 (executor):** Write `docs/lightcraft-behavior.md`. It contains:
  - a table with one row per question asked in Steps 2–5, giving what was observed and what follows from it
  - **"Task 12 needed: yes/no"**: yes if any Loupe field was dropped, or if a stale or default value was written back
  - the edit-marker setting needed for LightCraft exports
- [ ] **Step 7:** Owner removes the probe folder from LightCraft's catalog. Executor runs `mv ~/Pictures/_loupe-lc-probe ~/.Trash/`. Commit: `docs: LightCraft XMP behaviour probe`.

### Task 3: Migration rehearsal with osxphotos, plus real sidecar fixtures

**Files:**
- Create: `migration/export-from-photos.sh`, `migration/README.md`, `Tests/LoupeXMPTests/Fixtures/osxphotos-{album-favorite,edited,faces}.xmp`

**Interfaces:**
- Produces: `migration/export-from-photos.sh <destination> [extra osxphotos args…]`, used again in Task 21. It also produces fixtures and the expected metadata for Task 5.

- [ ] **Step 1 (owner):** Run `! brew tap RhetTbull/osxphotos && brew install osxphotos`. If `osxphotos info` says it can't read the library, grant the terminal app Full Disk Access (System Settings → Privacy & Security), then re-run `! osxphotos info`.
- [ ] **Step 2:** Write `migration/export-from-photos.sh`. It runs `osxphotos export "$1" "${@:2}"` with these fixed options:

  ```
  --directory "{created.year}/{created.year}-{created.mm}-{created.dd}"
  --sidecar XMP --sidecar-drop-ext --edited-suffix "-edited"
  --keyword-template "{favorite?Favorite,}" --keyword-template "Albums|{folder_album}"
  --update --report "$REPORT"
  ```

  `REPORT` defaults to `migration/export-report-<timestamp>.csv`. Before the first real run, check each flag against `osxphotos help export`.
- [ ] **Step 3: Rehearsal.**
  1. Record `df -k ~`.
  2. Export one small album (30 items or fewer, ideally including a favorite, an edited photo, a RAW+JPEG pair and a Live Photo) into `~/Pictures/_migration-test`.
  3. Export a few photos that are in no album: `--not-in-album --from-date <a recent date>`.
  4. Record `df -k ~` again.

  Expected: used space grows by about the size of the sidecars only, a few MB, because the files are clones. **If it grows by about the size of the files, stop and tell the owner.** The full export would then need about 70 GB.
- [ ] **Step 4: Inspect the export and record the findings in `migration/README.md`:**
  - sidecars are `<stem>.xmp`
  - favorites carry `Favorite`
  - album photos carry `Albums|<album>` in `dc:subject`
  - photos in no album have no `Albums|` entry, or only `Albums|`/`Albums|_`
  - edits are named `<stem>-edited.jpeg`
  - Live videos are `<stem>.mov`
  - RAW pairs come out together
  - any ` (1)` collision names
- [ ] **Step 5:** Run a full dry run with `--dry-run` into `~/Pictures`. From the report, count the missing photos. Expected: 0. If it's more than 0, stop and tell the owner: those originals are only in iCloud, which needs `--download-missing --use-photokit` or turning off "Optimize Mac Storage".
- [ ] **Step 6 (informational):** Run `osxphotos import --check --walk "$HOME/Pictures/Photos iceland" ~/Pictures/*.jpg ~/Pictures/*.CR2`, checking the flags with `osxphotos help import` first. Report to the owner which loose files are already in Photos and would be duplicated by the export. Delete nothing.
- [ ] **Step 7: Fixtures.**
  1. Copy three sidecars into `Fixtures/`: one with favorite plus album, one for an edited photo, one with face regions.
  2. Replace person names with `Person A`/`Person B`, and GPS values with `0`.
  3. Record each fixture's expected `PhotoMetadata` in `migration/README.md`.
  4. Run `mv ~/Pictures/_migration-test ~/.Trash/`.
  5. Commit: `feat(migration): rehearsed osxphotos export script and fixtures`.

### Task 4: Core models and photo grouping

**Files:**
- Create: `Sources/LoupeCore/Models/{VersionKind,MediaFile,PhotoGroup}.swift`, `Sources/LoupeCore/Grouping/{MediaClassifier,PhotoGrouper}.swift`, `Tests/LoupeCoreTests/PhotoGrouperTests.swift`

**Interfaces:**
- Produces:
  - `public enum VersionKind: String, Codable, Sendable, CaseIterable { case raw, jpeg, heic, image, video, live, edit }`
  - `public struct MediaFile: Hashable, Sendable { public var url: URL; public var size: Int64; public var modified: Date; public var created: Date }`
  - `public struct GroupedVersion: Hashable, Sendable { public var file: MediaFile; public var kind: VersionKind }`
  - `public struct PhotoGroup: Hashable, Sendable { folder: URL; stem: String; stemKey: String; versions: [GroupedVersion]; sidecar: URL?; legacySidecars: [URL]; var displayVersion: GroupedVersion; var sidecarURLForWriting: URL; var allFiles: [URL] }`
    - `allFiles` = version URLs + sidecar + legacy sidecars.
  - `public enum MediaClassifier { public static func baseKind(forExtension: String) -> VersionKind? }`
    - Uses `UTType` conformance: `.rawImage` → raw, `.jpeg` → jpeg, `.heic`/`.heif` → heic, other `.image` → image, `.movie` → video, anything else → nil.
  - `public struct PhotoGrouper: Sendable { public init(editMarkers: [String]); public static func stemKey(_ stem: String) -> String; public func group(_ files: [MediaFile], sidecars: [URL], in folder: URL) -> [PhotoGroup] }`

- [ ] **Step 1: Write the failing tests.** One `@Test` per case:

  ```swift
  @Test func groupsRawAndJpegPair()        // [IMG_1.CR2, IMG_1.JPG] → 1 group, kinds [.raw,.jpeg], display .jpeg
  @Test func attachesEditByMarker()        // [IMG_1.CR2, IMG_1-edited.jpeg] → kinds [.raw,.edit], display .edit
  @Test func attachesParenthesisedEdit()   // [IMG_1.JPG, "IMG_1 (edited).jpg"] → 1 group
  @Test func chainsEdits()                 // [IMG_1.JPG, IMG_1-edit.jpg, IMG_1-edit-2.jpg] → 1 group, 2 edits, display = newer `modified`
  @Test func keepsUnrelatedDashedNames()   // "Screenshot 2026-10-12 at 10.23.07 AM.png", "… AM (2).png",
                                           // "mendel identity and access - edited.png", "mendel identity and access 1.png" → 4 groups
  @Test func neverMergesRawIntoAnother()   // [IMG_1.JPG, IMG_1-2.CR2] → 2 groups
  @Test func livePhotoVideoIsLive()        // [IMG_1.HEIC, IMG_1.MOV] → kinds [.heic,.live], display .heic
  @Test func loneVideoIsVideo()            // [vid1.mov] → [.video]
  @Test func stemsAreCaseInsensitive()     // [IMG_1.CR2, img_1.jpg] → 1 group
  @Test func stemsAreNormalisationInsensitive() // "Z\u{30C}lut\u{30C}.JPG" + "Žluť.CR2" → 1 group
  @Test func attachesSidecars()            // sidecars [IMG_1.XMP, IMG_1.CR2.xmp] → sidecar IMG_1.XMP, legacy [IMG_1.CR2.xmp];
                                           // no sidecar → sidecarURLForWriting == folder/IMG_1.xmp
  @Test func classifierIgnoresNonMedia()   // "txt", "xmp", "DS_Store" → nil
  ```
- [ ] **Step 2:** Run `swift test --filter PhotoGrouperTests`. Expected: FAIL, it does not compile.
- [ ] **Step 3: Implement `PhotoGrouper.group`** with this algorithm:
  1. `stemKey` = `stem.precomposedStringWithCanonicalMapping.lowercased()`. Put files into buckets by `stemKey`.
  2. Visit buckets in ascending key length. For a bucket with no RAW file, check each marker. For each occurrence of the marker in the stem, from the last occurrence to the first: if the prefix before it is the key of another bucket, move every file into that bucket's final target as `.edit`, then stop.
  3. Non-edit kinds come from `MediaClassifier`. A video in a group that also holds a non-edit image is `.live`.
  4. Sidecars: `<stem>.xmp` (extension and key compared case-insensitively) is the sidecar. `<member file name>.xmp` is a legacy sidecar.
  5. Order versions raw, jpeg, heic, image, live, video, then edits by `modified` ascending.
  6. Display version: newest edit, otherwise the first jpeg/heic/image, otherwise raw, otherwise live/video.
- [ ] **Step 4:** Run `swift test --filter PhotoGrouperTests`. Expected: PASS.
- [ ] **Step 5:** Commit: `feat(core): media classification and photo grouping`.

### Task 5: Reading XMP

**Files:**
- Create: `Sources/LoupeCore/Models/PhotoMetadata.swift`, `Sources/LoupeXMP/{XMPNamespaces,XMPDocument,EmbeddedMetadataReader}.swift`, `Sources/LoupeTestSupport/TestImages.swift`, `Tests/LoupeXMPTests/XMPReadTests.swift`, `Tests/LoupeXMPTests/Fixtures/{lightcraft-two-descriptions,lightcraft-single,attribute-form,malformed}.xmp`
  - The first two fixtures are copies of `~/Pictures/IMG_2174.xmp` and `eby.xmp`. The last two are hand-written.

**Interfaces:**
- Produces:
  - `public struct PhotoMetadata: Equatable, Sendable { rating = 0; tags: [String] = []; albums: [String] = []; isFavorite = false; hasLightCraftEdits = false }`
  - `public enum MetadataChange: Hashable, Sendable, Codable { case setRating(Int), setFavorite(Bool), addTag(String), removeTag(String), addToAlbum(String), removeFromAlbum(String) }`
  - `public enum Keywords { static let favorite = "Favorite"; static let albumPrefix = "Albums|" }`
  - `public enum XMPError: Error, Equatable { case malformed(String) }`
  - `public struct XMPDocument { public init(data: Data) throws; public var metadata: PhotoMetadata { get }; public var writerToolkit: String? { get } }`
    - `writerToolkit` is the `x:xmptk` value.
  - `public enum EmbeddedMetadataReader { public static func metadata(in imageURL: URL) -> PhotoMetadata? }`
    - Uses ImageIO `CGImageSourceCopyMetadataAtIndex` → `CGImageMetadataCreateXMPData` → `XMPDocument`.
  - `TestImages.makeJPEG(at: URL, width: Int, height: Int, orientation: Int = 1, exif: [CFString: Any] = [:], tiff: [CFString: Any] = [:], gps: Bool = false, embeddedXMP: (rating: Int, subjects: [String])? = nil) throws`

- [ ] **Step 1: Write the failing tests.**

  ```swift
  @Test func readsLightCraftTwoDescriptions()   // rating 0, tags [], albums [], hasLightCraftEdits true, writerToolkit "LightCraft"
  @Test func readsAttributeFormAndOtherPrefixes() // xap:Rating="3" attribute, dc:subject as rdf:Seq ["Iceland","Favorite","Albums|Trip"]
                                                  // → rating 3, tags ["Iceland"], albums ["Trip"], isFavorite true
  @Test func readsOsxphotosSidecars()           // each Task-3 fixture == expected values from migration/README.md
  @Test func ignoresPlaceholderAlbumNames()     // ["Albums|", "Albums|_", "Albums|Real"] → albums ["Real"]
  @Test func unionsHierarchicalAlbums()         // lr:hierarchicalSubject ["Albums|A","Places|Iceland"] + dc ["Albums|B"] → albums ["B","A"] (dc first), tags []
  @Test func rejectsMalformed()                 // #expect(throws: XMPError.self) { try XMPDocument(data: malformed) }
  @Test func readsEmbeddedXMP()                 // TestImages JPEG with embedded rating 2 + ["Embedded"] → rating 2, tags ["Embedded"]
  ```
- [ ] **Step 2:** Run `swift test --filter XMPReadTests`. Expected: FAIL.
- [ ] **Step 3: Implement**, parsing with `XMLDocument(data:options: [.nodePreserveAll])` and matching on **namespace URI, never on prefix**, across every `rdf:Description`:
  - **Rating:** the first `xmp:Rating`, as element text or attribute. Values outside 1…5 become 0.
  - **`dc:subject` items** (Bag or Seq): `Favorite` sets `isFavorite`. Items starting with `Albums|` are albums, ignoring `""` and `"_"`. Everything else is a tag. Duplicates are dropped, keeping the first.
  - **`lr:hierarchicalSubject`:** only the `Albums|` entries are used.
  - **LightCraft edits:** `hasLightCraftEdits` is true when any `lc:settings` has non-whitespace text.
- [ ] **Step 4:** Run `swift test --filter XMPReadTests`. Expected: PASS.
- [ ] **Step 5:** Commit: `feat(xmp): tolerant XMP reader`.

### Task 6: Writing XMP safely

**Files:**
- Create: `Sources/LoupeXMP/XMPDocument+Write.swift`, `Sources/LoupeXMP/SidecarIO.swift`, `Tests/LoupeXMPTests/XMPWriteTests.swift`

**Interfaces:**
- Consumes: `PhotoGroup` (Task 4), `XMPDocument`, `EmbeddedMetadataReader` (Task 5).
- Produces:
  - `extension XMPDocument { public static func empty() -> XMPDocument; public mutating func apply(_ changes: [MetadataChange]); public func serialized() -> Data }`
    - `empty()` is an xpacket with `x:xmptk="Loupe"`.
  - `public enum SidecarIO { public static func read(_ group: PhotoGroup) throws -> PhotoMetadata; @discardableResult public static func write(_ changes: [MetadataChange], to group: PhotoGroup) throws -> PhotoMetadata }`
    - `read` precedence: sidecar → first legacy sidecar → embedded XMP of the display version → `PhotoMetadata()`.

- [ ] **Step 1: Write the failing tests.**

  ```swift
  @Test func ratingChangeTouchesOnlyRating()   // lightcraft-two-descriptions + [.setRating(4)]:
      // String(decoding: out) == input.replacingOccurrences(of: "<xmp:Rating>0</xmp:Rating>", with: "<xmp:Rating>4</xmp:Rating>")
  @Test func keywordChangesPreserveForeignContent() // [.addTag("Iceland"), .addToAlbum("Trip"), .setFavorite(true)] → reparsed metadata
      // == PhotoMetadata(rating: 0, tags: ["Iceland"], albums: ["Trip"], isFavorite: true, hasLightCraftEdits: true);
      // lc:settings text identical; canonical XML equal after removing dc:subject and lr:hierarchicalSubject from both
  @Test func appleParserAgrees()               // CGImageMetadataCreateFromXMPData(out): xmp:Rating "4"; dc:subject ⊇ {"Iceland","Favorite","Albums|Trip"};
                                               // lr:hierarchicalSubject ⊇ {"Albums|Trip"}
  @Test func attributeRatingUpdatedInPlace()   // attribute-form + [.setRating(5)] → attribute == "5", no xmp:Rating element added
  @Test func removingLastTagRemovesProperty()  // only "Iceland" + [.removeTag("Iceland")] → no dc:subject element
  @Test func malformedSidecarIsNeverOverwritten() // write to malformed → throws; file bytes unchanged
  @Test func newSidecarIsSeededFromEmbedded()  // JPEG embedded rating 2 + ["Embedded"], no sidecar; write [.addTag("New")]
      // → <stem>.xmp exists; read → rating 2, tags ["Embedded","New"]; JPEG sha256 unchanged
  @Test func noOpWriteLeavesFileUntouched()    // adding an existing tag ("iceland" vs "Iceland") → modification date unchanged
  ```

  If the byte-exact test fails only because `XMLDocument` normalises the XML declaration or empty-element form, relax it to a comparison of `canonicalXMLStringPreservingComments(false)` and note that in the commit message.
- [ ] **Step 2:** Run `swift test --filter XMPWriteTests`. Expected: FAIL.
- [ ] **Step 3: Implement `apply`.**
  - **`setRating(n)`:** clamp to 0…5. Update `xmp:Rating` where it already is, element or attribute. Otherwise add an element to the first Description.
  - **`addTag`:** append to the `dc:subject` Bag unless a case-insensitive match exists.
  - **`removeTag`:** remove exact matches.
  - **`setFavorite`:** add or remove `Favorite` in `dc:subject`.
  - **`addToAlbum`/`removeFromAlbum`:** add or remove `Albums|<name>` in both `dc:subject` and `lr:hierarchicalSubject`.
  - Missing properties are created with an `rdf:Bag` in the first Description, declaring the namespace there if it isn't in scope. A property whose Bag becomes empty is removed.
- [ ] **Step 4: Implement `SidecarIO.write`.**
  - **Existing sidecar:** parse it (malformed → throw), apply, and if the bytes are unchanged, return without writing.
  - Before the atomic replace (`Data.write(options: .atomic)`), re-check the file's modification date. If it changed since the read, re-read and re-apply once.
  - **No sidecar:** start from `empty()`, seed it with `read(group)` expressed as changes, apply, then write to `sidecarURLForWriting`.
- [ ] **Step 5:** Run `swift test --filter XMPWriteTests`. Expected: PASS.
- [ ] **Step 6:** Commit: `feat(xmp): field-level sidecar writes that preserve foreign data`.

### Task 7: Media info, thumbnails, full-size loading

**Files:**
- Create: `Sources/LoupeMedia/{MediaInfo,MediaInfoReader,ThumbnailCache,ImageLoader}.swift`, `Tests/LoupeMediaTests/{MediaInfoTests,ThumbnailTests}.swift`

**Interfaces:**
- Consumes: `MediaFile`, `VersionKind` (Task 4); `TestImages` (Task 5).
- Produces:
  - `public struct MediaInfo: Equatable, Sendable { captureDate: Date?; pixelWidth: Int?; pixelHeight: Int?; cameraModel: String?; lensModel: String?; duration: Double?; hasLocation: Bool }`
  - `public enum MediaInfoReader { public static func read(_ url: URL, kind: VersionKind) async -> MediaInfo }`
  - `public actor ThumbnailCache { public init(directory: URL, maxPixelSize: Int = 512); public func thumbnail(for file: MediaFile, kind: VersionKind) async -> CGImage?; public nonisolated static func key(for file: MediaFile) -> String }`
  - `public enum ImageLoader { public static func image(at url: URL, maxPixelSize: Int) -> CGImage? }`

- [ ] **Step 1: Write the failing tests.**

  ```swift
  @Test func readsExifDateWithOffset()        // DateTimeOriginal "2026:09:06 14:30:00" + OffsetTimeOriginal "+02:00" → 2026-09-06T12:30:00Z
  @Test func swapsDimensionsForRotation()     // 400×300, orientation 6 → pixelWidth 300, pixelHeight 400
  @Test func readsCameraLensAndLocation()     // TIFF Model "Canon EOS 600D", EXIF LensModel "EF-S18-55mm", gps → hasLocation true
  @Test func thumbnailIsBoundedAndCached()    // 4000×3000 → long edge in 256...512; cache file at <dir>/<key.prefix(2)>/<key>.jpg;
                                              // delete source → second call still returns an image
  @Test func keyChangesWhenFileChanges()      // same path, different `modified` → different key
  @Test func unreadableMediaYieldsNil()       // 0-byte .jpg and junk-bytes .mov → MediaInfo has all nils/false; thumbnail nil; no cache file
  @Test func loaderAppliesOrientation()       // 400×300 orientation 6 → CGImage 300×400
  @Test(.enabled(if: FileManager.default.fileExists(atPath: devRaw))) func realRawGetsLargeThumbnail()
                                              // dev-library/IMG_2174.CR2 → long edge ≥ 256 (catches tiny embedded thumbnails)
  ```
- [ ] **Step 2:** Run `swift test --filter LoupeMediaTests`. Expected: FAIL.
- [ ] **Step 3: Implement `MediaInfoReader`.**
  - **Images:** use `CGImageSourceCopyPropertiesAtIndex`, with no decode.
    - Parse the date with the format `yyyy:MM:dd HH:mm:ss` in the `OffsetTimeOriginal` zone, falling back to `TimeZone.current`.
    - Swap width and height for orientations 5–8.
  - **Videos:** use `AVURLAsset`: `.duration`, `.creationDate`, and the first video track's `naturalSize` with `preferredTransform` applied.
- [ ] **Step 4: Implement `ThumbnailCache`.**
  - **Key:** SHA-256 hex of `"\(path)|\(size)|\(modified.timeIntervalSince1970)"`. Files are JPEGs at quality 0.8.
  - **Images:** ImageIO thumbnail with `FromImageIfAbsent` + `WithTransform` + `MaxPixelSize`. If that returns nil, or the long edge is under `maxPixelSize/2`, retry with `FromImageAlways`.
  - **Videos:** `AVAssetImageGenerator` with `appliesPreferredTrackTransform` and `maximumSize`, at `min(1 s, duration/2)`.
  - **Failure:** return nil and write no cache file.
- [ ] **Step 5: Implement `ImageLoader`** as the ImageIO thumbnail API with `FromImageAlways` + `WithTransform` + `maxPixelSize`. This also renders RAW with Apple's default processing.
- [ ] **Step 6:** Run `swift test --filter LoupeMediaTests`. Expected: PASS.
- [ ] **Step 7:** Commit: `feat(media): EXIF/video info, thumbnail cache, image loader`.

### Task 8: Index database and scanner

**Files:**
- Create: `Sources/LoupeCore/Models/{PhotoRecord,VersionRecord,LibrarySettings}.swift`, `Sources/LoupeCore/Extensions/StorageLocation.swift`, `Sources/LoupeIndex/{Schema,LibraryIndex,Scanner}.swift`, `Sources/LoupeTestSupport/TestLibrary.swift`, `Tests/LoupeIndexTests/ScannerTests.swift`

**Interfaces:**
- Consumes: `PhotoGrouper` (Task 4), `SidecarIO.read` (Task 6), `MediaInfoReader` (Task 7). Thumbnails are made lazily by the grid, not by the scanner.
- Produces:
  - `public struct PhotoRecord: Codable, Hashable, Sendable, Identifiable`, with these fields:
    - `id: Int64?`, `locationId`, `folderPath` (relative, `""` = root), `stem`, `stemKey`
    - `captureDate: Date?`, `addedDate: Date`
    - `rating`, `isFavorite`, `hasLightCraftEdits`
    - `cameraModel?`, `lensModel?`
    - `hasRaw`, `hasVideo`
    - `sidecarModified: Date?`
    - computed `key: String`: `stem` when at root, otherwise `folderPath + "/" + stem`
  - `public struct VersionRecord: Codable, Hashable, Sendable, Identifiable { id: Int64?; photoId: Int64; path: String (relative); kind: VersionKind; size: Int64; modified: Date; pixelWidth: Int?; pixelHeight: Int?; duration: Double?; isDisplay: Bool; func url(in root: URL) -> URL }`
  - `public struct LibrarySettings: Codable, Equatable, Sendable { rootPath: String; editMarkers = ["-", "_edited", " (edited"]; excludedFolderNames = ["LightCraft Library"]; recentlyAddedDays = 30; static func standard() -> LibrarySettings }`
    - `standard()` uses `rootPath = ~/Pictures`.
  - `public protocol StorageLocation: Sendable { var id: String { get }; var displayName: String { get }; var rootURL: URL { get } }`
  - `public struct LocalFolderLocation: StorageLocation { public init(rootURL: URL) }`, with id `"local"` and display name `"Mac"`.
  - `public final class LibraryIndex: Sendable`, with:
    - `public init(databaseURL: URL) throws`, which runs migrations
    - `photo(id:)`, `photo(key:)`, `versions(ofPhoto:)`, `metadata(ofPhoto:) -> PhotoMetadata`, `groupFiles(ofPhoto:root:) -> PhotoGroup`
  - `public struct ScanReport: Equatable, Sendable { added = 0; updated = 0; removed = 0; failed: [String] = []; scannedPhotoIDs: [Int64] = [] }`
  - `public final class Scanner: Sendable { init(index:location:settings:); func fullScan() async throws -> ScanReport; func rescan(folder relativePath: String) async throws -> ScanReport }`
  - Package: add the GRDB dependency (`from: "7.0.0"`) and the `LoupeIndex` target here.
  - `TestLibrary`: builds temporary trees of generated images, fake RAW bytes and sidecars.

- [ ] **Step 1: Write the failing tests.**

  ```swift
  @Test func indexesTreeAndSkipsExcluded()    // a/IMG_1.CR2 + a/IMG_1.JPG, b/x.png, .hidden/y.jpg, Test.photoslibrary/z.jpg,
                                              // "LightCraft Library/thumbs/t.jpg", notes.txt → exactly photos "a/IMG_1" (raw+jpeg) and "b/x"
  @Test func metadataComesFromSidecar()       // a/IMG_1.xmp rating 3, tag "Iceland", album "Trip" → record + tag/album rows match
  @Test func rescanPicksUpEditAndDeletion()   // add a/IMG_1-edited.jpg → rescan("a") → edit version isDisplay; delete b/x.png → rescan("b") → removed
  @Test func rebuildFromDiskIsIdentical()     // fullScan into two fresh DBs → equal sets of (key, rating, tags, albums, version paths)
  @Test func unchangedFilesAreNotReread()     // second fullScan → added == 0 && updated == 0
  @Test func oddNamesSurvive()                // "Screan shots:recording/Screenshot … AM (2).png" and an NFD name → indexed; photo(key:) finds both
  @Test func unreadableFilesAreNotFatal()     // 0-byte broken.jpg + another photo with malformed sidecar → both indexed;
                                              // failed contains the sidecar path; the malformed file is unchanged
  ```
- [ ] **Step 2:** Run `swift test --filter ScannerTests`. Expected: FAIL.
- [ ] **Step 3: Implement the schema.** Migration `"v1"` creates:
  - `photo`: the `PhotoRecord` columns, with `UNIQUE(locationId, folderPath, stemKey)` and indexes on `captureDate` and `folderPath`
  - `version`: `path UNIQUE`, `photoId` referencing `photo` with `ON DELETE CASCADE`
  - `photo_tag(photoId, name, PK both)`
  - `photo_album(photoId, name, PK both)`
  - `mirror_state(photoId, storeId, state BLOB, PK both)`

  GRDB record conformances live in `LoupeIndex` as extensions.
- [ ] **Step 4: Implement `Scanner`.**
  - Walk with `FileManager.enumerator` using `[.skipsHiddenFiles, .skipsPackageDescendants]`, and call `skipDescendants()` for excluded folder names.
  - Group each folder with `PhotoGrouper(editMarkers:)`.
  - A group is unchanged when the stored versions' `(path, size, modified)` and the sidecar's modification date are equal.
  - New or changed groups: read `MediaInfo` for the new or changed versions and `SidecarIO.read`, then upsert the photo, replace its versions, and replace its tag and album rows. A malformed sidecar gives `PhotoMetadata()` plus an entry in `failed`, and is never written.
  - `captureDate`: from the display version's info, otherwise the first version that has one, otherwise the display file's creation date.
  - `addedDate`: the display file's creation date.
  - Delete DB photos that were not seen. A full scan also deletes photos in folders that no longer exist.
- [ ] **Step 5:** Run `swift test --filter ScannerTests`. Expected: PASS.
- [ ] **Step 6:** Commit: `feat(index): SQLite index and incremental folder scanner`.

### Task 9: Queries, sections and albums.json

**Files:**
- Create: `Sources/LoupeCore/Models/PhotoQuery.swift`, `Sources/LoupeIndex/{PhotoQueries,AlbumCatalog}.swift`, `Tests/LoupeIndexTests/{QueryTests,AlbumCatalogTests}.swift`

**Interfaces:**
- Consumes: `LibraryIndex`, records (Task 8).
- Produces:
  - `public struct PhotoQuery: Hashable, Sendable`, with:
    - `var scope: Scope`, where `Scope` is `.all`, `.favorites`, `.recentlyAdded(days: Int)`, `.album(String)`, `.tag(String)` or `.folder(String)`
    - `var searchText = ""`
    - `var minRating = 0`
    - `var kind: KindFilter = .any`, where `KindFilter` is `.any`, `.hasRaw`, `.withoutRaw`, `.videos` or `.lightCraftEdited`
    - `var camera: String?`, `var lens: String?`
    - `var sort: SortField = .captureDate`, where `SortField` is `.captureDate`, `.added`, `.name` or `.rating`
    - `var ascending = true`
    - `var grouping: Grouping = .none`, where `Grouping` is `.none`, `.day`, `.month` or `.year`
  - `public struct PhotoSection: Hashable, Sendable { id: String; title: String; photoIDs: [Int64] }`
  - `extension LibraryIndex`:
    - `sections(for: PhotoQuery, calendar: Calendar = .current, locale: Locale = .current, now: Date = .now) throws -> [PhotoSection]`
    - `observeSections(for: PhotoQuery) -> AsyncThrowingStream<[PhotoSection], Error>`, a GRDB `ValueObservation` that keeps GRDB out of the UI
    - `allTags()`, `albumNames() -> Set<String>`, `folderPaths()`, `cameras()`, `lenses()`
  - `public struct AlbumCatalog: Codable, Equatable { var version = 1; var albums: [AlbumEntry] }` and `public struct AlbumEntry: Codable, Equatable { var name: String; var cover: String? }`
    - `cover` is a photo key.
  - `public enum AlbumCatalogIO { static func url(root: URL) -> URL; static func load(root: URL) throws -> AlbumCatalog; static func save(_: AlbumCatalog, root: URL) throws }`
  - `public enum AlbumCatalogError: Error { case corrupt }`
  - `extension AlbumCatalog { public func orderedNames(including known: Set<String>) -> [String] }`

- [ ] **Step 1: Write the failing tests.**

  ```swift
  @Test func scopesSelectTheRightPhotos()    // favorites, album "Trip", tag "Iceland", folder "a" (non-recursive), recentlyAdded(30) via addedDate
  @Test func searchMatchesNamesTagsAlbumsCameraLens() // "ice" matches tag "Iceland"; "600d" matches camera; "IMG_1" matches stem
  @Test func filtersApply()                  // minRating 3; .hasRaw; .videos; .lightCraftEdited
  @Test func sortsWithUndatedLast()          // captureDate ascending and descending; nil captureDate always last
  @Test func groupsIntoTitledSections()      // gregorian/UTC/en_US: .day → "Sunday, September 6, 2026"; .month → "September 2026";
                                             // .year → "2026"; undated → "Undated" (last)
  @Test func observationEmitsAfterInsert()   // first emission, then insert a photo → next emission contains it
  @Test func albumOrderFollowsCatalog()      // catalog [B, A], known {A, B, C} → [B, A, C]
  @Test func catalogRoundTripsAndRejectsCorrupt() // save/load equal; missing file → empty catalog; "{oops" → throws .corrupt
  ```
- [ ] **Step 2:** Run `swift test --filter QueryTests` and `--filter AlbumCatalogTests`. Expected: FAIL.
- [ ] **Step 3: Implement.**
  - The SQL `WHERE` clause comes from the scope and filters.
  - Search is a case-insensitive `LIKE` over stem, folder path, camera and lens, plus `EXISTS` subqueries on tags and albums.
  - Sections are grouped in Swift after fetching `(id, captureDate)`. Titles use `DateFormatter.setLocalizedDateFormatFromTemplate`: `"EEEEdMMMMyyyy"`, `"MMMMyyyy"`, `"yyyy"`.
  - `albums.json` is written atomically as pretty-printed JSON with sorted keys.
- [ ] **Step 4:** Run the same commands. Expected: PASS.
- [ ] **Step 5:** Commit: `feat(index): queries, date sections, album catalog`.

### Task 10: Library façade, metadata edits and the folder watcher

**Files:**
- Create: `Sources/LoupeCore/Extensions/MetadataStore.swift`, `Sources/LoupeIndex/Extensions/FeatureRegistry.swift`, `Sources/LoupeIndex/{Library,FolderWatcher}.swift`, `Tests/LoupeIndexTests/{LibraryTests,FolderWatcherTests}.swift`

**Interfaces:**
- Consumes: `Scanner`, `LibraryIndex` (Task 8), `SidecarIO` (Task 6), `ThumbnailCache` (Task 7), `AlbumCatalogIO` (Task 9).
- Produces:
  - `public protocol MetadataStore: Sendable { var id: String { get }; func push(_ metadata: PhotoMetadata, files: [URL], lastState: Data?) throws -> Data; func pull(files: [URL], lastState: Data?) throws -> [MetadataChange] }`
  - `public struct FeatureRegistry: Sendable { public var metadataStores: [any MetadataStore] = []; public init() }`. Later tasks add `actions`, `shareExporters` and `sidebarSections`.
  - `public final class FolderWatcher: @unchecked Sendable { init(root: URL, latency: TimeInterval = 0.3, onChange: @escaping @Sendable (_ folders: Set<URL>, _ rescanAll: Bool) -> Void); func start(); func stop() }`
  - `public actor Library`, with:
    - `init(location: any StorageLocation, settings: LibrarySettings, registry: FeatureRegistry, supportDirectory: URL, cacheDirectory: URL) throws`
    - `nonisolated let index: LibraryIndex`
    - `nonisolated let thumbnails: ThumbnailCache`
    - `nonisolated let location: any StorageLocation`
    - `func start() async -> ScanReport`
    - `func apply(_ changes: [MetadataChange], to photoIDs: [Int64]) async -> [Int64: any Error]`
    - `func handleFolderChanges(_ folders: Set<URL>, rescanAll: Bool) async`
  - Notification `Library.albumsDidChange`, posted when `.loupe/albums.json` changes.
  - Notification `Library.didLog`, with `userInfo["message"]: String`. This is Library's only channel to the activity log; the UI subscribes to it in Task 17.

- [ ] **Step 1: Write the failing tests.** They use a temporary root and a `RecordingStore: MetadataStore` that counts pushes and returns scripted pull results.

  ```swift
  @Test func applyWritesSidecarAndIndex()        // [.setRating(4), .addTag("Iceland")] → sidecar has both; index rating 4, tags ["Iceland"]
  @Test func applyReportsPerPhotoFailures()      // one malformed sidecar + one fine → errors has only the malformed id; the fine one is written
  @Test func externalSidecarEditIsReloaded()     // write rating 5 to the sidecar directly → handleFolderChanges([folder]) → index rating 5
  @Test func ownWritesDoNotLoop()                // apply → handleFolderChanges → sidecar modification date unchanged; RecordingStore.pushes == 1
  @Test func storeChangesFlowIntoXMP()           // store pull returns [.addTag("FromStore")] once → handleFolderChanges → sidecar contains it
  @Test func applyToVanishedPhotoFailsCleanly()  // delete all files of a photo → apply → error for that id; handleFolderChanges removes the photo
  @Test func watcherReportsNewFile()             // start on a temp dir; create sub/new.jpg → onChange within 5 s with sub ∈ folders || rescanAll
  ```
- [ ] **Step 2:** Run `swift test --filter LibraryTests` and `--filter FolderWatcherTests`. Expected: FAIL.
- [ ] **Step 3: Implement `FolderWatcher`.**
  - Create the stream with `FSEventStreamCreate` and the flags `UseCFTypes | FileEvents | WatchRoot`, using `FSEventStreamSetDispatchQueue`.
  - Report the parent folder of each event path.
  - Report `rescanAll = true` for `MustScanSubDirs`, `RootChanged`, `UserDropped` or `KernelDropped`, and for a directory that was created or renamed.
- [ ] **Step 4: Implement `Library.apply`.** For each photo:
  1. `groupFiles` → `SidecarIO.write`.
  2. Update the photo row, its tags and albums, and `sidecarModified`.
  3. For each metadata store: `push(new, files: versionURLs, lastState)`, then save the state in `mirror_state`.

  Errors are collected per photo.
- [ ] **Step 5: Implement `handleFolderChanges`.**
  1. Map URLs to relative folders, posting `albumsDidChange` for `.loupe/`.
  2. Run `rescan`, or `fullScan` when `rescanAll` is set.
  3. For each photo in `scannedPhotoIDs` and each store: if `pull` returns changes, run `apply(changes, [id])`. If the photo was updated externally, `push` its current metadata.

  `start()` runs `fullScan`, pulls and pushes every photo, then starts the watcher.
- [ ] **Step 6:** Run both suites. Expected: PASS.
- [ ] **Step 7:** Commit: `feat(index): library façade, metadata edits, FSEvents watcher`.

### Task 11: Finder tags mirror (two-way)

**Files:**
- Create: `Sources/LoupeIndex/Extensions/LoupeFeature.swift`, `Sources/LoupeFeatures/FinderTags/{FinderTagStore,FinderTagsFeature}.swift`, `Tests/LoupeFeaturesTests/FinderTagStoreTests.swift`

**Interfaces:**
- Consumes: `MetadataStore`, `FeatureRegistry` (Task 10).
- Produces:
  - `public protocol LoupeFeature { static func register(in registry: inout FeatureRegistry) }`
  - `public struct FinderTagStore: MetadataStore`, with id `"finder-tags"`
  - `public enum FinderTagsFeature: LoupeFeature`

- [ ] **Step 1: Write the failing tests.** They use temporary files and set tags through `NSURL`.

  ```swift
  @Test func pushWritesMirrorSetToAllVersions()  // tags ["Iceland"], favorite, rating 3 → both files tagged {"Iceland","Favorite","★3"}
  @Test func pushThenPullIsNoOp()                // pull(files, lastState: pushResult) == []
  @Test func finderAddedTagBecomesKeyword()      // add "Trip" to the JPG only → [.addTag("Trip")]
  @Test func finderRemovedTagFromOneFile()       // remove "Iceland" from the RAW only → [.removeTag("Iceland")]
  @Test func favoriteTagMapsToFavorite()         // remove "Favorite" → [.setFavorite(false)]
  @Test func starTagsAreOneWay()                 // user adds "★5" → []
  @Test func firstSyncImportsExistingTags()      // lastState nil, file has "Red" → [.addTag("Red")]
  ```
- [ ] **Step 2:** Run `swift test --filter FinderTagStoreTests`. Expected: FAIL.
- [ ] **Step 3: Implement.**
  - **Mirror set:** tags ∪ {`Favorite` if favorite} ∪ {`★n` if `rating > 0`}.
  - **`push`:** write the set to every file with `(url as NSURL).setResourceValue(sortedArray, forKey: .tagNamesKey)`. `URLResourceValues.tagNames` is read-only. The state is the JSON-encoded sorted array.
  - **`pull`:** call `removeAllCachedResourceValues()` before reading each file's tags.
    - `added` = tags on any file − last − `★*`.
    - `removed` = { t ∈ last, not `★*` | some file lacks t }.
    - `Favorite` maps to `setFavorite`; anything else maps to `addTag`/`removeTag`.
    - When `lastState` is nil, `added` = all non-★ tags and `removed` is empty.
- [ ] **Step 4:** Run `swift test --filter FinderTagStoreTests`. Expected: PASS.
- [ ] **Step 5:** Commit: `feat(features): two-way Finder tag mirror`.

### Task 12: LightCraft stale-revert guard (only if Task 2 says "needed")

If `docs/lightcraft-behavior.md` says "Task 12 needed: no", write "skipped, see probe" in that file, commit, and move on.

**Files:**
- Create: `Sources/LoupeXMP/StaleRevertGuard.swift`, `Tests/LoupeXMPTests/StaleRevertGuardTests.swift`
- Modify: `Sources/LoupeIndex/{Schema,Library}.swift`. Migration `"v2"` adds `pending_edit(photoId, field, value, previous, PK(photoId, field))`.

**Interfaces:**
- Consumes: `Library.apply` and `handleFolderChanges` (Task 10), `XMPDocument.writerToolkit` (Task 5).
- Produces: `public enum StaleRevertGuard`, with:
  - `struct Pending: Hashable, Codable, Sendable { field: String; value: String; previous: String }`
    - `field` is `"rating"`, `"favorite"`, `"tag:<t>"` or `"album:<a>"`.
    - `value`/`previous` are the rating number, `"present"` or `"absent"`.
  - `static func pending(for: [MetadataChange], before: PhotoMetadata) -> [Pending]`
  - `static func evaluate(_ pending: [Pending], current: PhotoMetadata) -> (corrections: [MetadataChange], resolved: [Pending])`

- [ ] **Step 1: Write the failing tests.**

  ```swift
  @Test func staleRatingIsRestored()      // pending rating 4 (previous 0), current 0 → corrections [.setRating(4)], resolved []
  @Test func caughtUpIsResolved()         // current 4 → corrections [], resolved [the entry]
  @Test func differentValueWins()         // current 2 → corrections [], resolved [the entry]
  @Test func droppedKeywordsRestored()    // pending tag:Iceland present / album:Trip present; current lacks both → [.addTag("Iceland"), .addToAlbum("Trip")]
  @Test func libraryRestoresOnlyAfterLightCraftWrites() // apply rating 4 → write sidecar with x:xmptk="LightCraft" and rating 0 →
      // handleFolderChanges → sidecar rating 4 and one Library.didLog notification; same with x:xmptk="Other" → rating stays 0, no notification
  ```
- [ ] **Step 2:** Run `swift test --filter StaleRevertGuardTests`. Expected: FAIL.
- [ ] **Step 3: Implement.**
  - After every `apply`, upsert `pending(for:before:)`.
  - When a sidecar changed externally and `writerToolkit == "LightCraft"`, run `evaluate`:
    - apply the corrections, logged as "Restored <field> after LightCraft overwrote it"
    - delete the resolved entries
  - Entries are left alone for other writers, where disk wins.
- [ ] **Step 4:** Run the suite. Expected: PASS.
- [ ] **Step 5:** Commit: `feat(xmp): restore Loupe edits reverted by stale LightCraft writes`.

### Task 13: File operations (move, trash, folders)

**Files:**
- Create: `Sources/LoupeIndex/FileOperations.swift`, `Tests/LoupeIndexTests/FileOperationsTests.swift`
- Modify: `Sources/LoupeIndex/Library.swift`

**Interfaces:**
- Consumes: `PhotoGroup` (Task 4), `Library` (Task 10), `AlbumCatalogIO` (Task 9).
- Produces:
  - `public enum FileOperations { static func moveGroup(_ g: PhotoGroup, to destination: URL) throws -> PhotoGroup; static func trashGroup(_ g: PhotoGroup) throws -> [URL] }`
  - `extension Library`:
    - `move(_ ids: [Int64], toFolder: String) async -> [Int64: any Error]`
    - `trash(_ ids: [Int64]) async -> [Int64: any Error]`
    - `createFolder(named: String, inFolder: String) async throws -> String`
    - `renameFolder(_ relative: String, to newName: String) async throws -> String`

- [ ] **Step 1: Write the failing tests.**

  ```swift
  @Test func movesWholeGroupIncludingSidecars()   // CR2 + JPG + -edited.jpeg + .xmp + legacy .CR2.xmp all arrive in destination
  @Test func collisionRenamesWholeGroup()         // destination has IMG_1.JPG → "IMG_1 (1).CR2", "IMG_1 (1).JPG", "IMG_1 (1).xmp",
                                                  // "IMG_1 (1)-edited.jpeg"; grouping the destination gives 2 groups
  @Test func failedMoveRollsBack()                // delete one source file first → throws; remaining files still in source; destination empty
  @Test func trashRemovesAllFiles()               // all group files gone from the folder; resulting URLs exist (cleaned up afterwards)
  @Test func albumCoverFollowsMove()              // catalog cover "a/IMG_1" → move to "b" → "b/IMG_1"
  @Test func renameFolderReindexes()              // rename "a" → "c" → photo(key: "c/IMG_1") exists; "a/IMG_1" gone
  ```
- [ ] **Step 2:** Run `swift test --filter FileOperationsTests`. Expected: FAIL.
- [ ] **Step 3: Implement.**
  - **Collisions:** checked case-insensitively against existing names. Choose the lowest `n ≥ 1` such that `"<stem> (n)"` frees every file's name, and rename each file by replacing its leading stem.
  - **Rollback:** on any failure, move the files already moved back to the source, then rethrow. Trash rollback moves files back from the resulting URLs.
  - A move into the same folder does nothing.
  - **Afterwards:** rescan the source and destination folders, and rewrite album covers whose key changed. Finder tags travel with the files (xattrs) and albums live in the sidecars, so nothing else is rewritten.
- [ ] **Step 4:** Run the suite. Expected: PASS.
- [ ] **Step 5:** Commit: `feat(index): all-or-nothing group move/trash and folder ops`.

### Task 14: Actions extension point and Edit in…

**Files:**
- Create: `Sources/LoupeCore/Extensions/PhotoAction.swift`, `Sources/LoupeFeatures/EditIn/{EditInAction,EditInFeature,EditorPreferences}.swift`, `Tests/LoupeFeaturesTests/EditInTests.swift`
- Modify: `FeatureRegistry`, adding `public var actions: [any PhotoAction] = []`

**Interfaces:**
- Consumes: `PhotoRecord`, `VersionRecord` (Task 8), `LoupeFeature` (Task 11).
- Produces:
  - `public struct ActionSelection: Sendable { photos: [PhotoRecord]; versions: [Int64: [VersionRecord]]; focusedVersion: VersionRecord?; root: URL; func targetFiles() -> [URL] }`
    - `targetFiles()` returns the focused version if set, otherwise each photo's display version.
  - `@MainActor public protocol ActionContext: AnyObject { func share(_ urls: [URL]); func log(_ message: String); func present(_ error: any Error); func chooseApplication() async -> URL? }`
  - `public struct ActionMenuEntry: Identifiable { id: String; title: String; systemImage: String?; shortcut: Character?; isEnabled = true; children: [ActionMenuEntry] = []; perform: (@MainActor (any ActionContext) async throws -> Void)? }`
  - `public protocol PhotoAction: Sendable { var id: String { get }; @MainActor func entries(for: ActionSelection) -> [ActionMenuEntry] }`
  - `public enum EditorPreferences { public static var defaultEditor: URL? }`, stored in `UserDefaults` under `"editor.defaultAppPath"`.
  - `public struct EditInAction: PhotoAction { public init(appsForFile: @escaping @Sendable (URL) -> [URL] = { NSWorkspace.shared.urlsForApplications(toOpen: $0) }) }`, with id `"edit-in"`.

- [ ] **Step 1: Write the failing tests.**

  ```swift
  @Test func targetsFocusedVersion()     // focusedVersion = RAW → [raw url]
  @Test func targetsDisplayVersions()    // 2 photos, no focus → their display version urls
  @Test func editEntryShapeAndDefaultFirst() // one entry "Edit", shortcut "e"; children start with the default editor, then other apps,
                                         // end with "Choose Default Editor…"
  ```
- [ ] **Step 2:** Run `swift test --filter EditInTests`. Expected: FAIL.
- [ ] **Step 3: Implement the "Edit" entry.**
  - If no default editor is set, call `chooseApplication()`: an `NSOpenPanel` in `/Applications` limited to `.application`. Save the result as the default.
  - Open the files with `NSWorkspace.shared.open(targetFiles, withApplicationAt: app, configuration: .init())`.
  - Each child opens the files with its app once, without changing the default.
- [ ] **Step 4:** Run the suite. Expected: PASS.
- [ ] **Step 5:** Commit: `feat(features): action extension point and Edit in…`.

### Task 15: Share presets

**Files:**
- Create: `Sources/LoupeCore/Extensions/ShareExporter.swift`, `Sources/LoupeFeatures/Share/{OriginalExporter,JPEGExporter,ShareAction,ShareFeature,SharePreferences}.swift`, `Tests/LoupeFeaturesTests/ShareTests.swift`
- Modify: `FeatureRegistry`, adding `shareExporters`

**Interfaces:**
- Consumes: `PhotoAction` and `ActionContext` (Task 14), `TestImages` (Task 5).
- Produces:
  - `public protocol ShareExporter: Sendable { var id: String { get }; var title: String { get }; func canExport(_ kind: VersionKind) -> Bool; func export(_ file: URL, kind: VersionKind, removeLocation: Bool, into directory: URL) throws -> URL }`
  - `public struct OriginalExporter`, with id `"original"`.
  - `public struct JPEGExporter { init(id:title:maxLongEdge:quality:); static let highQuality = JPEGExporter(id: "hq", title: "High Quality", maxLongEdge: nil, quality: 0.85); static let small = JPEGExporter(id: "small", title: "Small", maxLongEdge: 2048, quality: 0.80) }`
  - `public enum SharePreferences { static var removeLocation: Bool }`, stored under `"share.removeLocation"`, default `true`.
  - `public struct ShareAction: PhotoAction { public init(exporters: [any ShareExporter]) }`, with id `"share"`.
  - `ShareFeature.register` appends `OriginalExporter()`, `.highQuality` and `.small` to `registry.shareExporters`, then appends `ShareAction(exporters: that same list)`.

- [ ] **Step 1: Write the failing tests.**

  ```swift
  @Test func smallResizesAndStripsGPS()   // 4000×3000 + GPS, removeLocation → 2048×1536, UTType .jpeg, no GPS dictionary
  @Test func keepsGPSWhenToggleOff()      // removeLocation false → GPS dictionary present
  @Test func neverUpscales()              // 1000×800 → 1000×800
  @Test func bakesOrientation()           // 400×300 orientation 6 → 300×400 pixels, orientation 1 or absent
  @Test func originalStripsGPSLosslessly()// JPEG + GPS → output has no GPS; same pixel size; source sha256 unchanged
  @Test func originalCopiesRawUnchanged() // fake .cr2 bytes → identical bytes
  @Test func menuFlagsKeptLocation()      // selection with a RAW + removeLocation → Original entry title "Original (location kept)";
                                          // JPEG presets disabled for a video-only selection
  ```
- [ ] **Step 2:** Run `swift test --filter ShareTests`. Expected: FAIL.
- [ ] **Step 3: Implement the exporters.**
  - **`JPEGExporter`:** for images, including RAW.
    - Each export goes to a fresh UUID subfolder of `directory` as `<stem>.jpg`.
    - Decode with the ImageIO thumbnail API: `FromImageAlways` + `WithTransform`, max size = `maxLongEdge ?? max(w, h)`.
    - Properties are the source EXIF/TIFF/IPTC with orientation 1, minus the GPS dictionary when `removeLocation` is on.
    - Quality goes in `kCGImageDestinationLossyCompressionQuality`.
  - **`OriginalExporter`:**
    - For JPEG, PNG or TIFF with `removeLocation` on: `CGImageDestinationCopyImageSource` with `kCGImageMetadataShouldExcludeGPS`.
    - Anything else is copied byte for byte.
- [ ] **Step 4: Implement `ShareAction`.** It shows a "Share" entry whose children are one entry per exporter plus a "Remove Location" toggle. Running an entry renders into `$TMPDIR/Loupe-Share/`, which is cleared at launch, then calls `context.share(urls)`. The UI shows the urls in an `NSSharingServicePicker`.
- [ ] **Step 5:** Run the suite. Expected: PASS.
- [ ] **Step 6:** Commit: `feat(features): share presets with location removal`.

### Task 16: Script actions

**Files:**
- Create: `Sources/LoupeFeatures/Scripts/{ScriptCatalog,ScriptRunner,ScriptsAction,ScriptsFeature}.swift`, `Tests/LoupeFeaturesTests/ScriptTests.swift`

**Interfaces:**
- Consumes: `PhotoAction` and `ActionContext` (Task 14), `PhotoRecord.key` (Task 8).
- Produces:
  - `public struct ScriptItem: Hashable, Sendable { url: URL; title: String; kind: Kind }`, where `Kind` is `.executable` or `.shortcut`.
  - `public struct ScriptCatalog { init(directory: URL); func scripts() -> [ScriptItem] }`
  - `public struct ScriptResult: Sendable { exitCode: Int32; output: String }`
  - `public enum ScriptRunner { static func run(_ item: ScriptItem, files: [URL], photoKeys: [String], kinds: [VersionKind]) async throws -> ScriptResult }`
  - `public struct ScriptsAction: PhotoAction { public init(directory: URL) }`, with id `"scripts"`. `ScriptsFeature` passes `~/Library/Application Support/Loupe/Scripts/`.

- [ ] **Step 1: Write the failing tests.**

  ```swift
  @Test func catalogListsExecutablesAndShortcuts() // run.sh (+x), notes.txt (not +x), "Resize for Web.shortcut" →
                                                   // titles ["Resize for Web", "run"], kinds [.shortcut, .executable]
  @Test func passesPathsWithSpacesVerbatim()       // script `echo "$#|$1"`, file ".../a b.jpg" → output "1|…/a b.jpg\n"
  @Test func setsEnvironmentAndHomebrewPath()      // `echo "$LOUPE_PHOTO_IDS|$LOUPE_VERSION_KINDS|$PATH"` → starts "a/IMG_1|raw|/opt/homebrew/bin:"
  @Test func reportsNonZeroExit()                  // `exit 3` → exitCode 3, no throw
  ```
- [ ] **Step 2:** Run `swift test --filter ScriptTests`. Expected: FAIL.
- [ ] **Step 3: Implement.**
  - **`ScriptCatalog`:** a script is an executable regular file or a `*.shortcut` file. Its title is the file name without extension. Sort with `localizedStandardCompare`.
  - **Executables:** run with `Process`:
    - arguments are the file paths, and the working directory is the scripts folder
    - environment is the current environment plus `PATH=/opt/homebrew/bin:/usr/local/bin:$PATH`, `LOUPE_PHOTO_IDS` (keys joined with `\n`) and `LOUPE_VERSION_KINDS` (kinds joined with `\n`)
    - stdout and stderr are merged
  - **Shortcuts:** run `/usr/bin/shortcuts run "<title>" --input-path <file>` once per file.
  - **`ScriptsAction`:** a "Scripts" submenu with one entry per script, which logs the title, exit code and output, followed by "Open Scripts Folder", which creates the folder if needed.
- [ ] **Step 4:** Run the suite. Expected: PASS.
- [ ] **Step 5:** Commit: `feat(features): script actions`.

### Task 17: App shell (window, sidebar, toolbar, settings)

**Files:**
- Create: `Sources/LoupeIndex/Extensions/SidebarSection.swift`, `Sources/LoupeFeatures/Sidebar/{BuiltInSidebarSections,SidebarFeature}.swift`, `Sources/LoupeFeatures/BuiltInFeatures.swift`, `Sources/LoupeUI/{AppModel,RootView,SidebarView,LibraryToolbar,SettingsView,ActivityLogView,KeyCommand}.swift`, `Tests/LoupeUITests/KeyCommandTests.swift`, `Tests/LoupeFeaturesTests/SidebarSectionTests.swift`
- Modify: `Sources/Loupe/LoupeApp.swift`, `FeatureRegistry` (adding `sidebarSections`)

**Interfaces:**
- Consumes: `Library` (Task 10), `AlbumCatalogIO` and `PhotoQuery` (Task 9), every feature from Tasks 11 and 14–16.
- Produces:
  - `public enum DropTarget: Hashable, Sendable { case folder(String), album(String) }`
  - `public struct SidebarItem: Identifiable, Hashable, Sendable { id: String; title: String; systemImage: String; scope: PhotoQuery.Scope; children: [SidebarItem] = []; dropTarget: DropTarget? }`
  - `public protocol SidebarSection: Sendable { var id: String { get }; var title: String? { get }; var order: Int { get }; func items(index: LibraryIndex, root: URL, settings: LibrarySettings) throws -> [SidebarItem] }`
  - `public enum BuiltInFeatures { public static let all: [any LoupeFeature.Type] = [SidebarFeature.self, FinderTagsFeature.self, EditInFeature.self, ShareFeature.self, ScriptsFeature.self] }`
  - `public enum BrowseMode { case years, months, days, all }`
  - `@MainActor @Observable public final class AppModel { library; registry; selectedItemID: String?; query: PhotoQuery; selection: Set<Int64>; viewerPhotoID: Int64?; mode: BrowseMode; columns: Int; scanStatus: String; log: [LogEntry] }`, conforming to `ActionContext`.
  - `public enum KeyCommand: Equatable { case rate(Int), toggleFavorite, edit, trash, toggleViewer, closeViewer, previous, next, zoomIn, zoomOut; static func from(characters: String, modifiers: NSEvent.ModifierFlags) -> KeyCommand? }`

- [ ] **Step 1: Write the failing tests.**

  ```swift
  @Test func mapsKeys()   // "0"…"5" → rate(n); "f" → toggleFavorite; "e" → edit; "\u{7F}"+command → trash; " " → toggleViewer;
                          // esc → closeViewer; ←/→ → previous/next; "="/"+" + command → zoomIn; "-" + command → zoomOut; "m" → nil (Phase 4)
  @Test func builtInSectionsForTestLibrary() // order Library, Favorites, Recently Added | Albums (catalog order) | Tags | Folders;
                          // folders walk the filesystem (empty folders included) and skip hidden/package/excluded; folder titles use
                          // FileManager.displayName (":" → "/")
  ```
- [ ] **Step 2:** Run `swift test --filter KeyCommandTests` and `--filter SidebarSectionTests`. Expected: FAIL.
- [ ] **Step 3: Implement the built-in sections and `KeyCommand`**, until the tests pass.

  | Item | SF Symbol |
  |---|---|
  | Library | `photo.on.rectangle` |
  | Favorites | `heart` |
  | Recently Added | `clock` |
  | Albums | `rectangle.stack` |
  | Tags | `tag` |
  | Folders | `folder` |

  Album and folder items carry drop targets.
- [ ] **Step 4: Wire the app.**
  - **Root:** `UserDefaults.standard.string(forKey: "LoupeRoot")`, otherwise the root from settings.
  - **Startup:** register `BuiltInFeatures`, create the support, cache and scripts directories, then run `Library.start()` in a background `Task`.
  - **Layout:** `NavigationSplitView` with the sidebar and a detail placeholder for Task 18.
  - **Toolbar:** segmented Years/Months/Days/All, a zoom slider, `.searchable`, a Filter menu (rating, kind, camera, lens), and a Sort menu.
  - **Sidebar footer:** "Scanning… N" while scanning, then "N photos".
  - **Settings scene:** root folder (Choose…), edit markers, excluded folder names, default editor, "Remove location when sharing". Changing the root, markers or exclusions recreates `Library`.
  - **Activity log panel:** toggled with ⌥⌘L.
- [ ] **Step 5:** Run `swift test`. Expected: all PASS.
- [ ] **Step 6: Manual check with `scripts/run-dev.sh`.**
  - The sidebar shows `Photos iceland` and `Screan shots/recording`, but not `LightCraft Library` or `Test.photoslibrary`.
  - The footer reaches "N photos".
  - Settings persist across relaunch.
- [ ] **Step 7:** Commit: `feat(ui): app shell, sidebar, toolbar, settings`.

### Task 18: Photo grid

**Files:**
- Create: `Sources/LoupeUI/Grid/{PhotoGridView,PhotoGridController,PhotoCell,SectionHeaderView,GridLayout}.swift`, `Sources/LoupeIndex/CellInfo.swift`, `scripts/make-perf-library.sh`, `Tests/LoupeUITests/GridLayoutTests.swift`, `Tests/LoupeIndexTests/CellInfoTests.swift`

**Interfaces:**
- Consumes: `observeSections` (Task 9), `ThumbnailCache` (Task 7), `AppModel` and `KeyCommand` (Task 17), `registry.actions` (Tasks 14–16), and `Library.apply`/`trash` (Tasks 10 and 13).
- Produces:
  - `public struct CellInfo: Hashable, Sendable { id: Int64; displayFile: MediaFile; displayKind: VersionKind; rating: Int; isFavorite: Bool; hasLightCraftEdits: Bool; badges: [String] }`
  - `extension LibraryIndex { func cellInfo(ids: [Int64], root: URL) throws -> [Int64: CellInfo] }`
  - `public enum GridLayout { static func itemSide(containerWidth: CGFloat, columns: Int, spacing: CGFloat = 2) -> CGFloat; static func defaultColumns(for: BrowseMode) -> Int; static let columnRange = 3...15 }`
    - Default columns: years 14, months 10, days 5, all 7.

- [ ] **Step 1: Write the failing tests.**

  ```swift
  @Test func itemSideFillsWidth()   // width 1000, 7 columns, spacing 2 → (1000 - 12) / 7
  @Test func defaultColumnsPerMode()
  @Test func badges()               // raw+jpeg → ["RAW","JPG"]; heic+live → ["LIVE"]; video 12 s → ["0:12"]; 3723 s → ["1:02:03"]
  ```
- [ ] **Step 2:** Run `swift test --filter GridLayoutTests` and `--filter CellInfoTests`. Expected: FAIL. Then implement `GridLayout` and `cellInfo` until they PASS.
- [ ] **Step 3: Implement the grid.**
  - **Structure:** an `NSCollectionView` with a compositional layout:
    - square items with 2 pt spacing
    - pinned section headers on a material background in Days, Months and Years modes
    - a diffable data source keyed by `Int64`, fed from `observeSections`
  - **Cells:** aspect-fill thumbnails loaded asynchronously, with cancellation on reuse, an `NSCache` of 1,000 entries, and `NSCollectionViewPrefetching`.
  - **Badges:**
    - bottom-left: kinds or video duration
    - top-right: a heart for favorites
    - bottom-right: `★n`
    - top-left: `slider.horizontal.3` for LightCraft edits
  - **Selection:** click, ⇧ and ⌘ multi-select, ⌘A and arrow keys, all kept in sync with `AppModel.selection`. Double-click or space opens the viewer.
  - **Context menu:** the registry's action entries.
  - **Keys:** rate and favorite go through `Library.apply`. ⌘⌫ opens a confirmation sheet ("Move N photos (M files) to Trash?") before `Library.trash`.
  - **Zoom:** ⌘+ and ⌘-, pinch, and the toolbar slider change `columns`.
  - **Drag out:** writes the display-version file URLs plus the pasteboard type `local.loupe.photo-ids`.
- [ ] **Step 4: Manual check with `scripts/run-dev.sh`.**
  - The modes switch with correct headers, and zoom works.
  - Badges are correct: `IMG_9744` shows RAW, JPG and an edit; videos show a duration; `eby` and `IMG_2174` show the LightCraft icon.
  - Pressing 3 shows ★3 at once, and `grep Rating` on the sidecar shows 3.
  - F toggles the heart. ⌘⌫ asks first.
  - Dragging to Finder copies the file.
- [ ] **Step 5: Performance check.** `scripts/make-perf-library.sh` APFS-clones dev images into `dev-library/perf/` under 5,000 unique names. Expected:
  - scrolling is smooth from top to bottom at 7 and 15 columns
  - memory stays stable in Activity Monitor
  - the first-scan time is logged
- [ ] **Step 6:** Commit: `feat(ui): Photos-style grid with modes, badges, keys, drag-out`.

### Task 19: Photo viewer

**Files:**
- Create: `Sources/LoupeUI/Viewer/{PhotoViewer,ZoomableImageView,VideoPlayerView,VersionStrip,InfoPanel}.swift`, `Sources/LoupeMedia/ExifSummary.swift`, `Tests/LoupeMediaTests/ExifSummaryTests.swift`

**Interfaces:**
- Consumes: `ImageLoader` (Task 7), `versions(ofPhoto:)` (Task 8), `AppModel` and `KeyCommand` (Task 17), action entries with `focusedVersion` (Tasks 14 and 15).
- Produces: `public enum ExifSummary { static func lines(for url: URL) -> [(label: String, value: String)] }`

- [ ] **Step 1: Write the failing test.**

  ```swift
  @Test func formatsExposure()   // FNumber 2.8, ExposureTime 0.004, ISO 100, FocalLength 35 → values contain "ƒ/2.8", "1/250 s", "ISO 100", "35 mm"
  ```
- [ ] **Step 2:** Run `swift test --filter ExifSummaryTests`. Expected: FAIL. Implement it, then PASS.
- [ ] **Step 3: Implement the viewer.**
  - **Display:** an overlay above the grid. It shows the thumbnail instantly, then `ImageLoader.image(maxPixelSize: window pixels)`.
  - **Zoom:** an `NSScrollView` magnification view; double-click toggles fit and 100%.
  - **Navigation:** ←/→ move through the current query order and prefetch neighbours. Esc or space closes and selects the current photo in the grid.
  - **Video:** `.video` and `.live` versions play in `AVPlayerView`.
  - **Version strip:** buttons labelled "<KIND> <EXT> <size>", for example "RAW CR2 23.6 MB" or "EDIT JPEG 4.1 MB". Each sets `focusedVersion`.
  - **Bottom bar:** Edit ▾ and Share ▾ (registry entries for `focusedVersion`), Show in Finder (`activateFileViewerSelecting`), and an (i) button.
  - **(i) panel:** `ExifSummary`, dimensions, file size, path, rating, tags and albums.
- [ ] **Step 4: Manual check.**
  - `IMG_2174.CR2` shows a full RAW render.
  - The `IMG_9744` strip switches RAW, JPG and EDIT.
  - `vid1.mov` plays.
  - E with RAW focused opens the RAW in LightCraft.
  - Share ▾ Small produces a 2048 px JPEG in the share sheet.
- [ ] **Step 5:** Commit: `feat(ui): viewer with versions, info, edit and share`.

### Task 20: Organising (tags, albums, folders, drag and drop)

**Files:**
- Create: `Sources/LoupeUI/Organize/{TagEditorView,AlbumMenu,SidebarCommands}.swift`, `Tests/LoupeIndexTests/AlbumOperationsTests.swift`
- Modify: `Sources/LoupeIndex/Library.swift`, `Sources/LoupeUI/SidebarView.swift`, `Sources/LoupeUI/Grid/PhotoGridController.swift`

**Interfaces:**
- Consumes: `Library.apply`/`move`/`createFolder`/`renameFolder` (Tasks 10 and 13), `AlbumCatalogIO` (Task 9), `DropTarget` (Task 17).
- Produces: `extension Library`, with:
  - `createAlbum(_ name: String, adding: [Int64]) async throws`
  - `renameAlbum(_ old: String, to new: String) async throws -> [Int64: any Error]`
  - `deleteAlbum(_ name: String) async -> [Int64: any Error]`
  - `setAlbumCover(_ album: String, photoID: Int64) async throws`
  - `reorderAlbums(_ names: [String]) async throws`

- [ ] **Step 1: Write the failing tests.**

  ```swift
  @Test func createAlbumCanBeEmpty()        // createAlbum("Empty", adding: []) → catalog lists "Empty"; Albums section shows it
  @Test func renameAlbumRewritesMembers()   // 2 photos in "Trip" → rename "Iceland 2026" → sidecars have Albums|Iceland 2026 and no Albums|Trip;
                                            // catalog entry renamed with cover kept
  @Test func renameToExistingNameFails()    // throws; nothing written
  @Test func deleteAlbumKeepsFiles()        // members lose Albums|Trip; files still exist; catalog entry gone
  ```
- [ ] **Step 2:** Run `swift test --filter AlbumOperationsTests`. Expected: FAIL. Implement it, then PASS.
- [ ] **Step 3: Implement the UI.**
  - **Tag editor (⌘T):** a token field. Tags on every selected photo appear normal; tags on only some appear dimmed. Adding or removing a token applies the change to the whole selection.
  - **Context menus:**
    - "Add to Album ▸", listing albums plus New Album…
    - "Make Album Cover", when viewing an album
    - "New Folder…" and "Rename…" on folders
  - **Album sidebar menu:** "Rename…", and "Delete…", which confirms with "Photos stay in their folders."
  - **Drag and drop:** reordering albums in the sidebar calls `reorderAlbums`. Photo IDs dropped on a folder call `Library.move`; dropped on an album, they call `addToAlbum`.
- [ ] **Step 4: Manual check.**
  - The tag editor works on a mixed selection.
  - Album create, rename, delete, reorder and cover work.
  - Dropping onto a folder moves the files, visible in Finder.
  - A tag added in Finder appears in Loupe within about 1 s.
  - An album created in Loupe shows in `.loupe/albums.json`.
- [ ] **Step 5:** Commit: `feat(ui): tags, albums, folders, drag and drop`.

### Task 21: Migration and first real run

**Files:**
- Create: `docs/phase1-verification.md`

- [ ] **Step 1:** Run `swift test`. Expected: all PASS. Then run `scripts/bundle.sh release`.
- [ ] **Step 2: Full export (owner present).**
  1. Record `df -k ~`.
  2. Run `migration/export-from-photos.sh ~/Pictures`, which uses `--update` and so is resumable.
  3. Check the report: 0 errors and 0 missing.
  4. Record `df -k ~` again. The delta should be small.
- [ ] **Step 3:** Launch `build/Loupe.app` without `-LoupeRoot`, so it uses the default `~/Pictures`. Record the first-scan duration, and compare the photo count with the number of exported originals in the report.
- [ ] **Step 4: Spot checks.**
  - The Favorites count equals the count of favorites in Photos (`osxphotos query --favorite`).
  - Two albums have the right member counts.
  - RAW+JPEG pairs are grouped. Live Photos show LIVE. Photos edits appear as EDIT. Videos play.
  - `eby` and `IMG_2174` show the LightCraft badge.
  - `LightCraft Library` is absent.
- [ ] **Step 5: LightCraft round trip on a real photo.**
  1. Rate it 4 and tag it `test` in Loupe.
  2. Press E, edit it in LightCraft and let it auto-write.
  3. Loupe still shows ★4 and `test`, with Task 12 restoring them if needed. The badge updates. A `{name}-edited` export appears as EDIT.
- [ ] **Step 6:** Scroll through the whole library at 15 columns. Note any stutter in `docs/phase1-verification.md`, along with all the results above.
- [ ] **Step 7:** Commit: `docs: phase 1 verification on the real library`.

This task does **not** delete the Photos library; that is the owner's decision once they trust Loupe.

---

## Verification (end to end)

- **Automated:** `swift test` from `~/Github/loupe`. Every suite passes.
- **Dev app:**
  - `scripts/make-dev-library.sh && scripts/run-dev.sh`, then walk the manual checklists in Tasks 17–20.
  - Afterwards, `git status` in `~/Pictures` shows nothing (it isn't a repo), and the `stat` modification times of the originals cloned in `dev-library/` are unchanged.
- **Real library (Task 21):** results are recorded in `docs/phase1-verification.md`.
- **Data-safety invariants**, checked once more before Task 21: run `shasum` over 20 random image and video files in `dev-library/` before and after a session of rating, tagging, moving and sharing. Content hashes must be unchanged; only paths may differ after moves.

## Execution

Recommended: **subagent-driven**. Each task has an implementer and a fresh reviewer. Many tasks hand interfaces to each other, and mistakes in Tasks 6, 11 and 13 would damage real files. Native execution is cheaper but has no review until the end.

Rough cost estimate for this plan: about 25–45M tokens subagent-driven, or about 18–30M native.
