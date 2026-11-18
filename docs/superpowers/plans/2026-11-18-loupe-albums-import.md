# Loupe — Folder albums, Unsorted, SD card import (Tasks 20′, 22, 23)

> **For agentic workers:** executed with superpowers:subagent-driven-development on branch `phase1`, after Task 19. Steps use checkbox (`- [ ]`) syntax. Global Constraints from `2026-11-18-loupe-phase1.md` still apply unless changed below.

**Goal:** after trying Phase 1, the owner decided:

- albums are real folders
- photos not in any album live in **Unsorted**
- photos can be imported from an SD card, with **Import All New** skipping anything already on the Mac

**Owner decisions (2026-11-18)**

| Topic | Decision |
|---|---|
| Album | A folder that directly contains photos or videos. An empty folder is also an album, so "New Album" can create one. The library root is never an album. |
| Group | A folder with no direct media but with subfolders (for example `2026` holding `Iceland 2026`). It expands in the sidebar, and selecting it shows every photo below it. |
| One album per photo | A photo is in exactly one album. "Add to album" and dropping onto an album **move the files** (all versions and sidecars) with `Library.move`. |
| Unsorted | Photos loose in the library root. Imports land there unless an album is chosen. |
| Already on the Mac | A card file is present if any file in the library root tree **or the Apple Photos library** (`<root>/Photos Library.photoslibrary/originals`, when readable) has the same size and then the same SHA-256. |
| Keyword albums | `Albums|…` keywords already in sidecars are still read, preserved and indexed (`photo_album`), but the UI no longer shows or writes them. |

This supersedes spec decision #6, "virtual albums + tags (files stay put)".

**Global Constraints changes**

- Allowed writes add **copying new files into the library** (import only). The source card is never written.
- New paths: none. The import cache lives in the index DB, migration `v3`.
- New target `LoupeImport` depends on LoupeCore, LoupeMedia and LoupeIndex. `LoupeImportTests` depends on LoupeImport and LoupeTestSupport. `LoupeUI` also depends on LoupeImport.

Test command: `scripts/test.sh [--filter X]`. Tests use temp dirs only. Afterwards `ls ~/Library/Preferences | grep -c '^loupe-'` must print 0.

---

### Task 20: Folder albums, Unsorted, groups, organising

Replaces the original Task 20.

**Files:**
- Create:
  - `Sources/LoupeCore/Models/AlbumTree.swift`
  - `Sources/LoupeUI/Organize/{TagEditorView,AlbumMenu,SidebarCommands}.swift`
  - `Tests/LoupeCoreTests/AlbumTreeTests.swift`
  - `Tests/LoupeIndexTests/FolderAlbumOperationsTests.swift`
- Modify:
  - `Sources/LoupeCore/Models/PhotoQuery.swift`
  - `Sources/LoupeIndex/PhotoQueries.swift`
  - `Sources/LoupeIndex/Library.swift`
  - `Sources/LoupeFeatures/Sidebar/BuiltInSidebarSections.swift`
  - `Sources/LoupeUI/{SidebarView,AppModel}.swift`
  - `Sources/LoupeUI/Grid/PhotoGridController.swift`
  - the tests for QueryTests and SidebarSectionTests

**Interfaces:**
- `public struct AlbumNode: Hashable, Sendable { public enum Kind: Sendable { case album, group }; path: String; name: String; kind: Kind; children: [AlbumNode] }`
  - `path` is root-relative and NFC.
- `public enum AlbumTree { public static func build(_ folders: [FolderInfo]) -> [AlbumNode] }`, where `public struct FolderInfo: Sendable { path: String; directMediaCount: Int; hasSubfolders: Bool }`.
  - Rules:
    - the root (`""`) is excluded
    - `directMediaCount > 0` → album
    - `directMediaCount == 0 && !hasSubfolders` → album (empty)
    - otherwise → group
  - An album may also have children, for example an album with a subfolder.
  - Siblings are sorted with `localizedStandardCompare`.
- `PhotoQuery.Scope` adds:
  - `.unsorted`, meaning `folderPath = ""`
  - `.folderTree(String)`, meaning `folderPath = p OR folderPath LIKE p || '/%'` (escaped, NFC)
- `extension LibraryIndex { func directMediaCounts() throws -> [String: Int] }`, from `SELECT folderPath, COUNT(*) FROM photo GROUP BY folderPath`.
- `extension Library`:
  - `deleteAlbum(_ path: String) async -> [Int64: any Error]`: moves every photo whose `folderPath == path` to `""` via `move`, then removes the folder only if it is now empty, ignoring `.DS_Store`. It never trashes anything. Subfolders keep the folder in place.
  - `photoIDs(inFolder:)` helper, or reuse a query.
- Sidebar order:
  1. **Library**, **Favorites**, **Recently Added**, **Unsorted** (`tray`, scope `.unsorted`, `DropTarget.folder("")`)
  2. **Albums** section as a tree:
     - group: `folder` symbol, scope `.folderTree(path)`, no drop target
     - album: `rectangle.stack` symbol, scope `.folder(path)`, `DropTarget.folder(path)`
  3. **Tags**

  Remove `FoldersSidebarSection` and the keyword `AlbumsSidebarSection`.

  Build the tree from the existing filesystem walk (hidden, package and excluded folders skipped through `Scanner.ignores(folder:settings:)`) plus `directMediaCounts()`. That walk runs off the main thread, as it does today.

- [ ] **Step 1: Write the failing tests.**

  ```swift
  // AlbumTreeTests
  @Test func folderWithMediaIsAlbum()        // [a(3)] → [album a]
  @Test func emptyFolderIsAlbum()            // [e(0, no subfolders)] → [album e]
  @Test func folderWithOnlySubfoldersIsGroup()// [2026(0, subs), 2026/Iceland(5)] → [group 2026 [album Iceland]]
  @Test func albumWithSubfolderKeepsChildren()// [a(2, subs), a/b(1)] → [album a [album b]]
  @Test func rootIsNeverAnAlbum()            // ["" (4)] → []
  @Test func siblingsSortNaturally()         // "Trip 10", "Trip 2" → ["Trip 2","Trip 10"]
  // QueryTests
  @Test func unsortedScopeIsRootOnly()       // root photo + a/ photo → only root photo
  @Test func folderTreeScopeIsRecursive()    // 2026/a, 2026/b/c, 2027/x → .folderTree("2026") gives 2 (escape % and _ in names)
  // SidebarSectionTests (update)
  @Test func builtInSectionsForTestLibrary() // Library, Favorites, Recently Added, Unsorted | Albums tree | Tags; no "Folders" section;
                                             // group items have no drop target; album items DropTarget.folder(path); ":" shows as "/"
  // FolderAlbumOperationsTests
  @Test func newEmptyAlbumIsListed()         // createFolder("Empty", inFolder: "") → sidebar has album "Empty"
  @Test func newAlbumInsideGroup()           // createFolder("Iceland", inFolder: "2026") → group 2026 › album Iceland
  @Test func moveIntoAlbumMovesFiles()       // root IMG_1 (CR2+JPG+xmp) → move to "a" → files in a/, index folderPath "a", Unsorted empty
  @Test func deleteAlbumReturnsPhotosToUnsorted() // a/IMG_1 → deleteAlbum("a") → files in root, folder a gone, nothing in Trash
  @Test func deleteAlbumKeepsFolderWithSubfolders() // a/IMG_1 + a/b/IMG_2 → deleteAlbum("a") → IMG_1 in root, a/b intact
  ```
- [ ] **Step 2:** Run the new filters. Expected: FAIL.
- [ ] **Step 3: Implement the model, the queries, `deleteAlbum` and the sidebar** until the tests pass.
- [ ] **Step 4: Implement the UI.**
  - **Sidebar context menu:**
    - New Album… (on Unsorted, a group or an album: creates the folder inside it; on the section header: inside the root)
    - Rename… (`renameFolder`)
    - Delete Album… (confirmation: "Photos in <name> move to Unsorted. Subfolders stay.")
  - **Grid context menu:**
    - "Add to Album ▸", listing the album tree with New Album… at the end
    - "Move to Unsorted"
  - **Drag and drop:**
    - Photo ids dropped on an album or Unsorted call `Library.move`. Read `local.loupe.photo-ids` as **one decimal id per `NSPasteboardItem`**.
    - Drops on groups are refused.
    - Finder files dropped on an album are out of scope.
  - **Tag editor (⌘T):** a token field. Tags on every selected photo look normal; tags on only some photos are dimmed. Adding or removing a token applies the change to the whole selection through `Library.apply`.
  - Show per-photo errors from moves through `AppModel.present`. `FileOperationError` messages are already readable.
- [ ] **Step 5:** Run `scripts/test.sh`. Expected: all PASS. `scripts/bundle.sh debug` builds.
- [ ] **Step 6: Manual check (controller), with `scripts/run-dev.sh`:**
  - Unsorted lists the loose dev photos.
  - Albums shows `Photos iceland` (with `Girl from the diner` inside it) and `Screan shots/recording`.
  - New Album creates a Finder folder.
  - Drag onto it moves the files.
  - Delete Album returns the photos to Unsorted.
  - ⌘T edits tags.
- [ ] **Step 7:** Update the spec:
  - § Data model: albums are folders; Unsorted; groups.
  - § Main UI: sidebar.
  - Decision #6 is superseded.

  Commit: `feat(ui): folder albums, Unsorted, groups, tag editor`.

### Task 22: Import core (card detection, dedupe, verified copy)

**Files:**
- Create:
  - `Sources/LoupeImport/{CardDetector,CardListing,DuplicateFinder,Importer,ImportRecord}.swift`
  - `Tests/LoupeImportTests/{CardListingTests,DuplicateFinderTests,ImporterTests}.swift`
- Modify:
  - `Package.swift`
  - `Sources/LoupeIndex/Schema.swift` (migration `v3`)
  - `Sources/LoupeIndex/FileOperations.swift` (extract the collision chooser)

**Interfaces:**
- `public struct Card: Hashable, Sendable { volumeURL: URL; name: String; dcimURL: URL }`
- `public final class CardDetector: @unchecked Sendable { init(volumesURL: URL = URL(fileURLWithPath: "/Volumes"), notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter, onChange: @escaping @Sendable ([Card]) -> Void); func start(); func stop(); func currentCards() -> [Card] }`
  - A card is any directory under `volumesURL` with a `DCIM` subdirectory.
  - It rescans on `NSWorkspace.didMountNotification` and `didUnmountNotification`.
- `public enum CardListing { static func groups(on card: Card, editMarkers: [String]) throws -> [PhotoGroup] }`
  - Walks `DCIM/**` read-only, skips hidden files, groups each folder with `PhotoGrouper`, and returns groups across folders sorted by stem.
- `public struct DuplicateFinder`:
  - `init(index: LibraryIndex, root: URL, photosLibrary: URL?)`
  - `func present(_ groups: [PhotoGroup], progress: …) async throws -> DuplicateReport`
  - `DuplicateReport { presentFiles: Set<URL>; photosLibraryChecked: Bool }`
  - A group is "On Mac" when **all** of its media files are present.
  - Algorithm:
    1. Map size → [candidate paths] from `version` rows. Add a stat-only walk of `photosLibrary/originals` if it is readable; set `photosLibraryChecked = false` if it isn't (permission error).
    2. For each card file with size candidates, compare its SHA-256 with each candidate's. Card files with no size match are never hashed.
    3. Candidate hashes are cached in `file_hash(path PK, size, modified, sha256)` (migration `v3`) and reused when size and modified are unchanged.
- `public struct ImportPlan: Sendable { groups: [PhotoGroup]; destinationFolder: String }`
  - `destinationFolder` is root-relative: `""` means Unsorted.
- `public final class Importer: Sendable`:
  - `init(root: URL, index: LibraryIndex, editMarkers: [String])`
  - `func run(_ plan: ImportPlan, progress: @Sendable (ImportProgress) -> Void) async throws -> ImportResult`
  - `ImportResult { imported: [String] /*dest relative paths*/; skipped: [URL]; failed: [URL: any Error] }`
- `import_record(sha256 PK, sourceName, importedAt)`, also in migration `v3`.
- `FileOperations`: extract `static func freeStemSuffix(for names: [String], stem: String, in destination: URL, editMarkers: [String]) throws -> Int`, reused by both `moveGroup` and `Importer`.

**Import rules:**
1. Create the destination folder if it is missing (for example `2026/Card test`).
2. Before copying, check that available capacity (`volumeAvailableCapacityForImportantUsage`) is at least 1.05 × the total bytes. Otherwise throw `notEnoughSpace(needed:available:)`.
3. Copy each group atomically:
   - Copy every file to `.<name>.loupe-import` in the destination, streaming in 4 MB chunks while computing SHA-256 of the source.
   - Re-read each temp file and compare SHA-256.
   - On any mismatch or error, remove the group's temp files and record the error. The group is all-or-nothing.
   - Otherwise rename the temp files to their final names, using the collision suffix from `freeStemSuffix`.
4. Record `import_record` for every file.
5. Never write anything under the card's volume. Original file names are kept, apart from the collision suffix.
6. Cancellation is checked between groups. A cancelled group's temp files are removed.
7. After `run`, the caller (Library) rescans the destination folder through its serial section. Add `Library.importFiles(_ plan:) async throws -> ImportResult`, which runs the importer and then rescans inside the serial section.

- [ ] **Step 1: Write the failing tests.** Fake volumes are temp dirs containing `NAME/DCIM/100CANON/…`.

  ```swift
  @Test func detectsCardsWithDCIM()          // volumes {A/DCIM, B/} → [A]
  @Test func listsAndGroupsCardContents()    // IMG_1.CR2 + IMG_1.JPG + IMG_2.CR2 → 2 groups
  @Test func sameSizeDifferentBytesIsNew()   // library file same size, different content → not present
  @Test func renamedCopyIsPresent()          // library has X.CR2 == card IMG_9.CR2 bytes → present
  @Test func photosLibraryOriginalsAreChecked() // fake "Photos Library.photoslibrary/originals/A/UUID.cr2" == card file → present
  @Test func unreadablePhotosLibraryIsReported()// chmod 000 originals → photosLibraryChecked == false, no throw (restore perms)
  @Test func hashesAreCached()               // second present() call doesn't re-read library files (count reads via injectable hasher)
  @Test func importCopiesAndVerifies()       // 2 groups → files in dest, sha256 equal to card, card dir listing+mtimes unchanged
  @Test func importIntoNewNestedAlbum()      // destination "2026/Card test" created
  @Test func collisionGetsSuffixNotOverwrite()// dest has IMG_1.CR2 (different bytes) → IMG_1 (1).CR2; original untouched
  @Test func corruptCopyIsCleanedUp()        // injected copier flips a byte → group failed, no files or temp files left
  @Test func notEnoughSpaceThrowsBeforeCopying() // injected capacity 10 bytes → throws, dest untouched
  @Test func reimportFindsNothingNew()       // import then present() again → all present
  ```
- [ ] **Step 2:** Run `scripts/test.sh --filter LoupeImportTests`. Expected: FAIL.
- [ ] **Step 3: Implement** until the tests pass. Hashing uses CryptoKit `SHA256`, streamed. The copier, capacity and hasher are injectable for tests.
- [ ] **Step 4:** Run `scripts/test.sh`. Expected: all PASS. Commit: `feat(import): card detection, dedupe against library and Photos, verified copy`.

### Task 23: Import UI

**Files:**
- Create:
  - `Sources/LoupeUI/Import/{ImportView,ImportModel,DestinationPicker}.swift`
  - `Sources/LoupeFeatures/Sidebar/DevicesSidebarSection.swift` (or an AppModel-provided section)
  - `Tests/LoupeUITests/ImportModelTests.swift`
- Modify:
  - `Sources/LoupeUI/{AppModel,RootView,SidebarView}.swift`
  - `Sources/LoupeFeatures/BuiltInFeatures.swift`

**Interfaces:**
- **Devices sidebar section:** shown only when cards are present. One item per card, with the `sdcard` symbol, showing the card name.
- **`@MainActor @Observable final class ImportModel`:**
  - Properties:
    - `card`
    - `groups`
    - `present: Set<URL>`
    - `photosLibraryChecked`
    - `selection`
    - `destination: Destination` (`.unsorted`, `.album(path)` or `.newAlbum(name:, inGroup: String?)`)
    - `phase: .listing / .checking / .ready / .importing(progress) / .done(result)`
  - Methods: `importAllNew()` and `importSelected()`.
  - The last destination is remembered through `PreferenceStore` under key `"import.lastDestination"`.
- **Import view** (replaces the grid while a card is selected):
  - A thumbnail grid of the card's groups. Present groups are dimmed and badged "On Mac". Thumbnails come from `ThumbnailCache` with the card file as the source; cache files go in the normal thumbs dir.
  - A header shows the number of new groups and files and their size.
  - The destination picker is a popup: Unsorted, the album tree and New Album…. New Album… takes a name and an optional group, and defaults the group to the current year, for example `2026` → `2026/<name>`.
  - **Import All New** (the default button) and **Import Selected**.
  - A progress bar with Cancel.
  - A notice when `photosLibraryChecked == false`: "Apple Photos library wasn't checked — give Loupe Full Disk Access in System Settings to include it."
  - When it finishes: a summary (imported, skipped, failed with reasons) plus "Show Album" and "Eject" (`NSWorkspace.shared.unmountAndEjectDevice(at:)`).

- [ ] **Step 1: Write the failing tests** (`ImportModelTests`, with injected `DuplicateFinder`/`Importer` fakes).

  ```swift
  @Test func importAllNewSkipsPresent()      // 3 groups, 1 present → importer receives 2
  @Test func newAlbumDestinationPath()       // .newAlbum("Iceland", inGroup: "2026") → plan.destinationFolder == "2026/Iceland"
  @Test func lastDestinationIsRemembered()   // in-memory PreferenceStore round trip
  ```
- [ ] **Step 2:** Run the filter. Expected: FAIL. Implement, then PASS.
- [ ] **Step 3: Implement the UI.** Run `scripts/test.sh` (all PASS) and `scripts/bundle.sh debug`.
- [ ] **Step 4: Manual check (controller), with the real card read-only and the dev library as root:**
  - Before: `ls -lT /Volumes/EOS_DIGITAL/DCIM/100CANON > before.txt`.
  - `EOS_DIGITAL` appears under Devices. It shows 126 items, of which 125 are new, and `IMG_2174` is marked "On Mac".
  - Import All New into New Album `Card test` in group `2026`. Expected:
    - `dev-library/2026/Card test/` has 125 CR2 files with the same SHA-256 as the card.
    - The sidebar shows the group `2026` containing the album `Card test`.
  - Run Import All New again. Expected: 0 new.
  - After: `ls -lT …` equals `before.txt` (the card is unchanged).
  - Clean up: delete `dev-library/2026`.
- [ ] **Step 5:** Commit `feat(ui): SD card import window with Import All New`. Update spec § Import with the dedupe scope and destination picker.

## Deferred

- **Task 3 (osxphotos migration):** the export must map Photos albums to folders. A photo that is in several Photos albums needs an owner decision at that time: one folder plus keywords, or duplicates.
- **Task 21:** the real-library run.
