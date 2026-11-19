# Loupe — Media Types and Utilities sidebar sections (Tasks 27–29)

> **For agentic workers:** run with superpowers:subagent-driven-development on branch `phase1`, after Task 26 (slideshow). Earlier plans' Global Constraints and owner decisions still apply. Test command: `scripts/test.sh [--filter X]`. Use temp dirs only; `ls ~/Library/Preferences | grep -c '^loupe-'` must be 0. SwiftUI's `@State` macro is unavailable with the Command Line Tools: use `State(initialValue:)` or model state instead.

**Goal (owner, 2026-11-19).** Add two Photos-style sidebar sections. Both go between the Library group and Albums.

| Section | Items |
|---|---|
| Media Types | Videos, Panoramas, RAW |
| Utilities | Recently Edited, Duplicates, Recently Deleted |

**Owner decisions**
- **Duplicates** are **exact copies only**: byte-identical media files (same size, then the same SHA-256). There is no look-alike matching.
- **Recently Deleted** lists only photos **Loupe** moved to the Trash that are still there. It has a **Recover** button that puts every file back. There is no permanent delete: emptying the Trash stays in Finder.

**Safety rules (binding)**
- Loupe never deletes anything permanently.
- The Duplicates view offers "Move to Trash" only for a copy that is **fully redundant**: every media file in that photo group has an identical copy in the photo being kept. A group with unique files, such as its own edit or RAW, is shown but can't be trashed from this view.
- Recover is all-or-nothing per photo. It uses the collision-safe group naming from Tasks 13 and 22, so it never overwrites anything.

---

### Task 27: Media Types (Videos, Panoramas, RAW)

**Files:**
- Modify:
  - `Sources/LoupeCore/Models/PhotoQuery.swift`: add `Scope.mediaType(MediaType)`, where `MediaType` is `.videos`, `.panoramas` or `.raw`.
  - `Sources/LoupeIndex/PhotoQueries.swift`
  - `Sources/LoupeFeatures/Sidebar/BuiltInSidebarSections.swift`, or the `AppModel` sidebar groups, wherever Library/Albums are built now.
  - Query and sidebar tests.

**Rules:**
- **Videos:** the display version is `.video`. Live Photos are not videos.
- **RAW:** `hasRaw`.
- **Panoramas:** the display version is an image whose long edge is at least **2×** its short edge. Use the version's `pixelWidth`/`pixelHeight`; they are already orientation-corrected. Videos are excluded. Do this with SQL over the display version row.
- **Sidebar:**
  - A "Media Types" section with Videos (`video`), Panoramas (`pano`) and RAW (`camera.aperture`).
  - Only types the library actually has are shown, using a cheap `EXISTS` query each.
  - Items have no drop target.

**Tests:**
- Each scope selects exactly the right photos. Cover a 3:1 pano, a 2:3 portrait (not a pano), a video and a RAW+JPEG pair.
- An empty type is hidden from the sidebar.

Commit: `feat: Media Types sidebar (videos, panoramas, RAW)`.

### Task 28: Utilities — Recently Edited and Duplicates

**Files:**
- Create:
  - `Sources/LoupeIndex/DuplicateIndex.swift`
  - `Sources/LoupeUI/Utilities/DuplicatesView.swift`
  - Tests.
- Modify:
  - `PhotoQuery`/`PhotoQueries`
  - `Scanner` (edit time)
  - `Schema`: migration `v6` adds `photo.lastEditedAt REAL NULL` and `duplicate_member(setId, versionPath, photoId, sha256)`.
  - The sidebar.

**Recently Edited**
- `lastEditedAt` is the larger of these two values:
  - the newest `.edit` version's `modified`
  - the sidecar's mtime, if the photo `hasLightCraftEdits`
- The scanner sets it.
- `Scope.recentlyEdited(days:)` uses the same window as Recently Added (`settings.recentlyAddedDays`). It is sorted newest edit first by default.
- Sidebar: Utilities ▸ Recently Edited (`slider.horizontal.3`).

**Duplicates**
- `DuplicateIndex.refresh(progress:)` runs as a background job in Library's serial-section style, with copying and hashing outside the lock:
  1. Group all `version` rows by `size`.
  2. For sizes with two or more files, hash them. Reuse the streamed SHA-256 and the `file_hash` cache from Task 22.
  3. Store each set of two or more files with an identical hash as `duplicate_member` rows.
- It runs after the initial scan and is incremental: only new or changed files are hashed. It can be cancelled.
- Never hash a file without a size match.
- `LibraryIndex.duplicateSets() -> [DuplicateSet]`. Each set has members (photo id, version path, kind, folder) and a `redundant` flag per photo group. A group is redundant when all of its media files are duplicated in another group of the set.
- **`DuplicatesView`** (shown for Utilities ▸ Duplicates, `square.on.square`):
  - A list of sets. Each shows thumbnails of each copy with its album/folder path, size and date.
  - Per set: "Keep this one" on a copy. Then "Move Other Copies to Trash" trashes only the **redundant** other groups through `Library.trash`, after a confirmation ("Move N photos to Trash? They're identical copies of …").
  - A non-redundant copy shows "Has its own files — not removable here".
  - A summary header shows "N duplicate sets, X MB reclaimable".
- The sidebar shows the count when it's greater than 0.

**Tests:**
- Same size with different bytes is not a duplicate.
- A renamed copy in another album is a duplicate.
- A RAW+JPEG pair is not a duplicate of itself.
- Redundancy: a group with an extra edit is not redundant.
- Trashing the redundant copies leaves the kept photo untouched (sha256).
- The incremental refresh hashes only new files (injectable hasher counter).
- `lastEditedAt` comes from both sources; the recently-edited window and sort.

Commit: `feat: Recently Edited and Duplicates utilities`.

### Task 29: Utilities — Recently Deleted with Recover

**Files:**
- Create:
  - `Sources/LoupeIndex/TrashLog.swift`
  - `Sources/LoupeUI/Utilities/RecentlyDeletedView.swift`
  - Tests.
- Modify:
  - `Library.trash` (record)
  - The sidebar.

**Interfaces:**
- **Durable record.** `<root>/.loupe/trash-log.json` is written atomically. It is not stored in the disposable index.
  - Each entry has: `id`, `deletedAt`, original folder (root-relative), original file names, the `trashedURLs` the Trash returned, the photo key, and a small metadata snapshot (rating, favorite, tags) for display.
  - `Library.trash` appends an entry per photo after a successful trash.
- **`TrashLog.entries()`** keeps only entries whose trashed files **all still exist**. Others (Trash emptied, or files restored by hand) are pruned from the file. Pruning only removes log entries, never files.
- **Recover:**
  1. Move every trashed file back into the original folder. If the folder is gone, recreate it. If that's impossible, recover into Unsorted.
  2. Original names are restored. On a collision, use the shared group-level `freeStemSuffix` with `moveItem` (never overwrite).
  3. All-or-nothing per entry: roll back on failure.
  4. Rescan the folder through the serial section, then remove the entry.
- **`RecentlyDeletedView`** (Utilities ▸ Recently Deleted, `trash`):
  - A grid of entries showing their thumbnail (from the trashed display file), name, original album and "Deleted <relative date>".
  - Select one or more, then **Recover**.
  - Footer: "Items stay here until you empty the Trash in Finder."
  - Empty state: "No Recently Deleted Photos".

**Tests:**
- Trash records an entry.
- Recover restores every file (RAW, JPEG, edit, sidecar) byte-identical into the original folder, and the index shows the photo again.
- Recover into a folder that now has a same-name photo gets the `(1)` suffix, and the original is untouched.
- Recovery when the original folder was deleted recreates it.
- An entry whose trashed file is gone is pruned, and nothing is deleted.
- Recover failure mid-way rolls back.

Tests use temp dirs as a fake "Trash": inject the trash function and the file locations. Never touch the real `~/.Trash`.

Commit: `feat: Recently Deleted with Recover`.
