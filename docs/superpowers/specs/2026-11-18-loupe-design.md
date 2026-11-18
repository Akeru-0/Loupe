# Loupe — design

*Working name. 2026-11-18.*

## Intent

A native macOS photo manager with an Apple Photos–like look and feel, built on
**ordinary folders** instead of a closed library. The owner likes how Photos
looks but not how it works:

- Photos hides originals inside its library; getting RAW files out is painful.
- Management and sorting are weak.
- They edit in an external editor (Lightcraft, free) and want any editor to
  work on the real files.

Success: they can retire Apple Photos for day-to-day use. Photos live in
`~/Pictures` as plain files, and every bit of organisation (ratings, tags,
albums, people) survives outside the app.

## Goals

1. Browse a folder tree under `~/Pictures` with a Photos-like UI: sidebar,
   zoomable grid (Years / Months / Days / All), full-screen viewer.
2. Group the files of one shot into a single **photo with versions**: RAW,
   JPEG, HEIC, and edits.
3. **Edit in…** opens the selected version in a chosen external editor, in one
   click.
4. **Share** with compression presets.
5. Organise two ways: **physical folders** (move/rename real files) and
   **virtual albums + tags** (files stay put).
6. Metadata stored in **XMP sidecars**, mirrored to **Finder tags**.
7. **SD card / camera import** like Photos.
8. **Local face recognition** with a People view.
9. **Script actions** (extensibility, approach B below).
10. *Later phase:* **server storage** on the owner's Linux box over Tailscale.

## Non-goals

- No built-in photo editor (no crop/adjust UI). Editing is external.
- No iCloud / PhotoKit integration. A one-off migration out of Photos is done
  with `osxphotos`, outside the app.
- No sync between multiple Macs.
- No third-party runtime plugin system (see Approaches).
- No iOS app.

## Anti-goals (failure even if it "works")

- **Lock-in.** If quitting the app loses ratings, albums, tags or face names,
  it has failed. The app's own database must be a **rebuildable cache** only.
- **Data loss.** The app must never delete or overwrite an original without a
  verified copy elsewhere. It must never overwrite another tool's XMP fields.
- **Sluggishness.** A Photos look with laggy scrolling defeats the point.
- **Copying Apple.** It should match Photos' style using standard macOS
  components. No Apple artwork, icons (other than SF Symbols), or branding.

## Constraints

- macOS 15+, Swift / SwiftUI (AppKit where needed). Single user, personal use.
- Built with SwiftPM and the Command Line Tools only (no Xcode installed; disk
  space is tight). No asset catalogs, no `#Preview`, and Swift Testing for tests.
- Videos (including Live Photo `.mov` companions) are shown and played from
  Phase 1.
- Current collection: about 3,000 photos, about 80 GB (mostly RAW). It must
  stay fast as this grows to tens of thousands.
- The owner builds and extends it with Claude Code, so the code should be
  modular and easy for an agent to navigate.

## Approaches

### Extensibility (decided: B)

| | Approach | Trade-off |
|---|---|---|
| A | Modular app with fixed extension points. Each feature is a module; adding one means a rebuild. | Nearly free; no runtime extension. |
| **B** | **A + script actions.** Any shell script or Shortcut in a folder appears in the right-click menu and receives the selected files. | +2–5M tokens. Covers small needs without a rebuild. |
| C | Real runtime plugins, loadable and shareable. | +20–40M tokens, plus the burden of keeping a stable plugin API forever. Only worth it if others write plugins. |

**Owner chose B.** They will add features themselves with Claude, so clean
internal seams plus scripts cover it.

### Overall build (builder's call, stated)

Native SwiftUI app. The grid uses `NSCollectionView` wrapped for SwiftUI,
because SwiftUI's lazy grids don't stay smooth at tens of thousands of items.
The index is SQLite (GRDB), treated as a disposable cache. Electron/web was
rejected: it can't match the native look or RAW performance.

## Design

### Data model

- **Location**: a root folder the app manages (`~/Pictures` at first; the server
  later). Pluggable (extension point).
- **Photo**: all files in the same folder sharing a base name, e.g.
  `IMG_1234.CR3`, `IMG_1234.JPG`, `IMG_1234.HEIC`, plus edits matching
  `IMG_1234-*.{jpg,tif,…}` / `IMG_1234 (edited)*`. The exact edit-filename
  patterns are configurable, because what Lightcraft writes on save is not yet
  confirmed.
- **Version**: one file of a photo, with a kind (RAW / JPEG / HEIC / Edit /
  other), size and dimensions.
- **Display version** (default): newest Edit, else JPEG/HEIC, else RAW.
- **Capture date** comes from EXIF, falling back to file creation date.

### Source of truth vs cache

| Data | Source of truth | Mirror / cache |
|---|---|---|
| Rating, tags, albums | XMP sidecar `<basename>.xmp` (one per photo) | Finder tags (tags + rating as "★3"); SQLite |
| Face regions + names | XMP, MWG Regions standard (`mwg-rs`) | SQLite |
| Face embeddings | — | SQLite only (rebuildable) |
| Album order, cover photo | `~/Pictures/.loupe/albums.json` (portable file next to the photos) | SQLite |
| Thumbnails | — | `~/Library/Caches/Loupe` |

**Albums** are XMP hierarchical keywords `Albums|<name>` (`lr:hierarchicalSubject`
plus flat `dc:subject`). Tags are plain keywords.

**XMP write rule:** read-modify-write. The app edits only `xmp:Rating`,
`dc:subject`, `lr:hierarchicalSubject` and `mwg-rs:Regions`; every other
namespace and field is preserved byte-for-byte. If an embedded-XMP-only JPEG has
no sidecar, create a sidecar; never rewrite the image file.

**Conflicts (builder's call, stated):** the sidecar on disk is the truth. The
app watches sidecars and reloads on external change, so the last writer wins
per field. Edits are applied as deltas against a fresh read of the file:
- Rating: replaced.
- Keywords: only the keywords the user added or removed in the app change.
- Face regions: only the regions the app created or the user renamed change.
  Regions from other tools are kept.

**Favorite (builder's call, stated):** the keyword `Favorite`. This is
independent of rating and visible in any tool that shows keywords. The Photos
migration maps Photos favorites to it.

**Finder tags (builder's call, stated):** two-way for tags. Adding or removing
a Finder tag in Finder updates XMP keywords. Rating (`★n`) is one-way, from XMP
to Finder. Tags are set on every version file of the photo.

**Sidecar naming:** `<basename>.xmp`. This matches Lightcraft, which writes
`IMG_1234.xmp` when a RAW is edited. The app also reads `<file>.<ext>.xmp`
(darktable style) if present.

**Sharing the sidecar with Lightcraft:** Lightcraft edits are non-destructive
develop settings stored in that same `.xmp`. They are not new image files.

*Verified 2026-11-18 on LightCraft 0.21.1 (`ai.storyteller.lightcraft`):*
- It is catalog-based, with its catalog in `~/Pictures/LightCraft Library`. That
  folder must be excluded from indexing.
- It writes `<stem>.xmp` with `x:xmptk="LightCraft"`. A file can contain two
  `rdf:Description` blocks.
- Develop settings are a **JSON string inside `<lc:settings>`** (namespace
  `http://ns.lightcraft.app/lc/1.0/`), not Camera Raw `crs:` fields.
- It writes `xmp:Rating` itself, as an element.
- Its preference `xmp.autoWrite` defaults to false, so the owner must turn it on
  for Loupe to see edits.
- Exports default to `~/Pictures/LightCraft Exports`, named `{name}`.

Therefore:
- The app and Lightcraft share one sidecar. The field-level merge rule above is
  mandatory, and Lightcraft's develop fields are never touched.
- A photo whose sidecar has a non-empty `lc:settings` gets an **"edited"** badge. The thumbnail
  still shows the default RAW render, because the app can't render Lightcraft's
  settings. An **Edit** version appears only when the owner exports a
  JPEG/TIFF into the same folder.
- **Phase 1 must verify** whether Lightcraft keeps foreign XMP fields when it
  saves, and whether its catalog writes stale values back.
- **Stale-revert guard**, used only if that check shows it's needed. After Loupe
  changes a field, it remembers the field's previous value. If a later
  LightCraft write (`x:xmptk="LightCraft"`) puts back exactly that previous
  value, or drops the keyword Loupe added, Loupe restores its own value and logs
  it. Any other value from LightCraft wins. This is the one exception to "disk
  wins".

A full re-scan of the folders plus XMP must rebuild everything except face
embeddings, which are recomputed.

### Main UI

```
┌ Sidebar ─────────┬ Toolbar: [Years|Months|Days|All]  zoom ─  🔍  [Import] ┐
│ Library          │                                                       │
│ Favorites        │   ▢ ▢ ▢ ▢ ▢ ▢     grid; badges per photo:             │
│ Recently Added   │   ▢ ▢ ▢ ▢ ▢ ▢     RAW  JPG  EDIT  ★  👤                │
│ People           │                                                       │
│ Albums ▸         │                                                       │
│ Tags ▸           │                                                       │
│ Folders ▸ (tree) │                                                       │
│ Imports          │                                                       │
└──────────────────┴───────────────────────────────────────────────────────┘
```

- Library = everything, sorted by capture date. Folders = the real tree; drag and
  drop moves real files (all versions + sidecar together).
- Sorting and filtering by date, rating, tag, camera, lens, file kind (e.g. "has
  RAW"), and people. Search across these fields.
- Keyboard-first: arrows, space (viewer), 0–5 (rating), F (favorite), E (edit),
  ⌘⌫ (move to Trash).
- Batch actions on a selection: rate, tag, add to album, move, share, script.

### Viewer + versions

```
┌──────────────────────────────────────────────┐
│                 [ photo ]                    │
├──────────────────────────────────────────────┤
│ ●RAW CR3 24MB │ JPG 6MB │ EDIT jpg 4MB       │
│ [Edit ▾]  [Share ▾]  [Show in Finder]  (i)   │
└──────────────────────────────────────────────┘
```

Clicking a version shows it. Edit and Share act on the selected version. (i)
shows EXIF.

### Edit in…

- On first use, pick an editor app. After that, Edit (button or E) opens the
  **selected version's file** in it. The ▾ menu lists other editors.
- A watcher on the folder picks up new or changed files and attaches them to
  the photo as versions; thumbnails refresh.

### Share

Presets: **Original**, **High quality** (full-size JPEG, ~85%), **Small**
(2048 px long edge, JPEG ~80%). "Remove location" is on by default. RAW is
rendered with Core Image's default RAW processing. Output goes to the system
share sheet, or can be dragged out.

### Import (SD card / camera)

- Detect mounted volumes with a `DCIM` folder (plus ImageCaptureCore for
  USB-connected cameras). Optionally auto-open the import window.
- The grid of card contents groups RAW+JPEG pairs. Already-imported items are
  greyed out (matched by a content hash, recorded per import). The default is
  "Import All New".
- Copy to `~/Pictures/YYYY/YYYY-MM-DD/` (pattern configurable), keeping
  original filenames. Name collisions get a suffix, never an overwrite.
- Verify each copy by checksum before marking it imported.
- After import: optionally eject; optionally delete from the card (off by
  default, only verified files).

### Faces (local)

- Vision framework for face detection. A bundled Core ML face-embedding model
  for recognition, run on device. **The builder picks the model, checking that
  its license allows personal use.** Nothing leaves the machine.
- Background job with progress; runs on new imports.
- The People view clusters faces. Name a cluster once; confirm or reject
  suggestions. Names and regions are written to XMP (MWG).

### Showing LightCraft edits (decided: A, with C as fallback)

LightCraft is open source (MIT/Apache), written in Rust, and modelled on
Lightroom. Its develop settings live in `<basename>.xmp` as JSON inside
`<lc:settings>`, verified 2026-11-18. The engine must render that JSON.

- **"Show edits" toggle** in the toolbar and viewer, with shortcut M. On: the
  grid and viewer show photos rendered with LightCraft's settings. Off:
  unedited originals. Rendered previews are cached and invalidated when the
  `.xmp` changes.
- **Approach A (chosen):** call LightCraft's own Rust processing engine from
  Swift through an FFI bridge, so renders match LightCraft.
- **Fallback C:** if the engine can't render a file (unsupported RAW, engine
  error), show the newest exported Edit version, and otherwise the unedited
  original with the "edited" badge.
- **Rejected B:** a home-made Core Image reimplementation of the settings
  would never match and would need endless tuning.
- **Must be removable.** The whole feature is one optional module behind a
  setting and a build flag. Turning it off, or deleting the module, leaves the
  app working with fallback C. The owner's instruction: if it stops working
  with a future LightCraft version, or becomes too much work, it gets switched
  off rather than fought.
- **Starts with a throwaway spike:** confirm the repository, that the engine
  builds as a library callable from Swift, which schema it reads, and render
  speed. If the spike fails, ship fallback C only.

### Script actions (extensibility B)

- Folder `~/Library/Application Support/Loupe/Scripts/`. Every executable or
  `.shortcut` reference there appears in the right-click → Scripts menu.
- Scripts receive the file paths of the selected versions as arguments, plus
  env vars (`LOUPE_PHOTO_IDS`, the version kind). New or changed files appear
  through the normal watcher.
- Output and errors are shown in a small log panel.

### Internal architecture (extension points)

Each feature is a Swift package/module registering into these points:
`SidebarSection`, `PhotoAction`, `Importer`, `StorageLocation`,
`MetadataStore` (XMP, Finder tags, faces), `BackgroundJob`, `ShareExporter`.
Built-in features use the same points. The server phase must arrive as a new
`StorageLocation` without changes to the core.

### Later phase: server storage

Recorded now so the core stays compatible:

- The owner's Linux box. Samba with `vfs_fruit` + `streams_xattr`, reached over
  Tailscale. Share on the 2 TB HDD, same dated layout.
- Library mixes Mac and Server. Each photo shows where it lives (Mac / Server /
  both). Thumbnails and metadata are cached locally, so the library browses
  offline.
- Import can also copy to the server. "Free up space" removes the Mac copy only
  after a byte-for-byte verified server copy. Edit on a server-only photo pulls
  it local first. Metadata edits made while offline are queued.
- **Open before this phase starts:** whether the 2 TB disk has a second copy
  anywhere. If not, "free up space" makes the server the only copy of the
  originals. Decide on a safeguard or an off-box backup (e.g. restic/rclone to
  cloud) first.

## Migration from Apple Photos (builder's call, stated)

The plan includes a tested `osxphotos export` command whose output matches the
app's conventions:
- dated `YYYY/YYYY-MM-DD` folders
- originals plus RAW, with edited versions as `-edited` files
- `<basename>.xmp` sidecars
- albums as `Albums|<name>` keywords, favorites as `Favorite`
- person names stay in the XMP that osxphotos writes (`mwg-rs` face regions plus
  `Iptc4xmpExt:PersonInImage`). They are not turned into keywords, which would
  flood Tags. Phase 3 reads them.

Before the plan is finalised, check it against `osxphotos export --help`.

## Phases

0. **Migration** command (above), run on a copy first.
1. **Core browser**: folder index, grid + viewer with Photos look, versions,
   Edit in…, Share presets, XMP + Finder tags, ratings/tags/albums, folder
   moves, search/filter, script actions.
2. **Import** from SD card / camera.
3. **Faces** + People.
4. **Show LightCraft edits** (spike first; optional module).
5. **Server storage.**

## Left to the builder

- Module/package layout, concurrency design, thumbnail pipeline details.
- Face-embedding model choice (license check).
- Exact Photos-like visual details: spacing, animations, the transition from
  grid to viewer.
- Test strategy (XMP round-trip and non-clobbering, import verification, and
  rebuild-from-disk deserve tests).
- The final app name.
