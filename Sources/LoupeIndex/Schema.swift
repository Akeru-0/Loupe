import GRDB

enum Schema {
    static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE photo (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    locationId TEXT NOT NULL,
                    folderPath TEXT NOT NULL,
                    stem TEXT NOT NULL,
                    stemKey TEXT NOT NULL,
                    captureDate DOUBLE,
                    addedDate DOUBLE NOT NULL,
                    rating INTEGER NOT NULL DEFAULT 0,
                    isFavorite BOOLEAN NOT NULL DEFAULT 0,
                    hasLightCraftEdits BOOLEAN NOT NULL DEFAULT 0,
                    cameraModel TEXT,
                    lensModel TEXT,
                    hasRaw BOOLEAN NOT NULL DEFAULT 0,
                    hasVideo BOOLEAN NOT NULL DEFAULT 0,
                    sidecarModified DOUBLE,
                    legacySidecarFingerprint TEXT,
                    UNIQUE(locationId, folderPath, stemKey)
                );
                CREATE INDEX photo_captureDate ON photo(captureDate);
                CREATE INDEX photo_folderPath ON photo(folderPath);
                CREATE TABLE version (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    photoId INTEGER NOT NULL REFERENCES photo(id) ON DELETE CASCADE,
                    path TEXT NOT NULL UNIQUE,
                    kind TEXT NOT NULL,
                    size INTEGER NOT NULL,
                    modified DOUBLE NOT NULL,
                    pixelWidth INTEGER,
                    pixelHeight INTEGER,
                    duration DOUBLE,
                    isDisplay BOOLEAN NOT NULL DEFAULT 0
                );
                CREATE INDEX version_photoId ON version(photoId);
                CREATE TABLE photo_tag (
                    photoId INTEGER NOT NULL REFERENCES photo(id) ON DELETE CASCADE,
                    name TEXT NOT NULL,
                    PRIMARY KEY (photoId, name)
                );
                CREATE TABLE photo_album (
                    photoId INTEGER NOT NULL REFERENCES photo(id) ON DELETE CASCADE,
                    name TEXT NOT NULL,
                    PRIMARY KEY (photoId, name)
                );
                CREATE TABLE mirror_state (
                    photoId INTEGER NOT NULL REFERENCES photo(id) ON DELETE CASCADE,
                    storeId TEXT NOT NULL,
                    state BLOB NOT NULL,
                    PRIMARY KEY (photoId, storeId)
                );
                """)
        }
        migrator.registerMigration("v2") { db in
            try db.execute(sql: """
                CREATE TABLE pending_edit (
                    photoId INTEGER NOT NULL REFERENCES photo(id) ON DELETE CASCADE,
                    field TEXT NOT NULL,
                    value TEXT NOT NULL,
                    previous TEXT NOT NULL,
                    PRIMARY KEY (photoId, field)
                );
                """)
        }
        migrator.registerMigration("v3") { db in
            // Import: SHA-256 cache of library and Photos-library files (reused while size and mtime match),
            // and a record of every file imported from a card.
            try db.execute(sql: """
                CREATE TABLE file_hash (
                    path TEXT PRIMARY KEY NOT NULL,
                    size INTEGER NOT NULL,
                    modified DOUBLE NOT NULL,
                    sha256 TEXT NOT NULL
                );
                CREATE TABLE import_record (
                    sha256 TEXT PRIMARY KEY NOT NULL,
                    sourceName TEXT NOT NULL,
                    importedAt DOUBLE NOT NULL
                );
                """)
        }
        migrator.registerMigration("v4") { db in
            // Rotation: the sidecar's tiff:Orientation, when it overrides the files' own orientation.
            try db.execute(sql: "ALTER TABLE photo ADD COLUMN orientationOverride INTEGER")
            try markSidecarPhotosForRescan(db)
        }
        migrator.registerMigration("v5") { db in
            // The turn every version gets: the override read against the file the sidecar describes. Photos with
            // a sidecar are re-read once so it is filled in (and a redundant override from v4 is dropped).
            try db.execute(sql: "ALTER TABLE photo ADD COLUMN rotation INTEGER")
            try markSidecarPhotosForRescan(db)
        }
        migrator.registerMigration("v6") { db in
            // Recently Edited: when the photo was last edited (the scanner sets it from now on).
            // Duplicates: the files with a byte-identical copy in another photo group, per duplicate set.
            try db.execute(sql: """
                ALTER TABLE photo ADD COLUMN lastEditedAt DOUBLE;
                CREATE INDEX photo_lastEditedAt ON photo(lastEditedAt);
                CREATE TABLE duplicate_member (
                    setId INTEGER NOT NULL,
                    versionPath TEXT PRIMARY KEY NOT NULL,
                    photoId INTEGER NOT NULL REFERENCES photo(id) ON DELETE CASCADE,
                    sha256 TEXT NOT NULL
                );
                CREATE INDEX duplicate_member_photoId ON duplicate_member(photoId);
                """)
            try fillLastEditedAt(db)
        }
        migrator.registerMigration("v7") { db in
            // Hide: the sidecar's "Hidden" keyword. Photos with a sidecar are re-read once so it is filled in.
            try db.execute(sql: "ALTER TABLE photo ADD COLUMN isHidden BOOLEAN NOT NULL DEFAULT 0")
            try markSidecarPhotosForRescan(db)
        }
        migrator.registerMigration("v8") { db in
            // library_meta: the root path, so library-relative paths can be matched with file_hash's absolute ones
            // (Imports). upload_state: what the cloud upload copied, by root-relative path, while size and mtime
            // still match. upload_failure: files whose last upload failed (Unable to Upload).
            try db.execute(sql: """
                CREATE TABLE library_meta (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL);
                CREATE TABLE upload_state (
                    path TEXT PRIMARY KEY NOT NULL,
                    size INTEGER NOT NULL,
                    modified DOUBLE NOT NULL,
                    uploadedAt DOUBLE NOT NULL
                );
                CREATE TABLE upload_failure (
                    path TEXT PRIMARY KEY NOT NULL,
                    photoId INTEGER NOT NULL REFERENCES photo(id) ON DELETE CASCADE,
                    message TEXT NOT NULL,
                    failedAt DOUBLE NOT NULL
                );
                CREATE INDEX upload_failure_photoId ON upload_failure(photoId);
                """)
        }
        migrator.registerMigration("v9") { db in
            // Faces and pets (LoupeFaces): which file each photo was scanned from (a changed file is scanned
            // again), what was found (box in the shown photo, 0…1 from the top left; the recognition vector), and
            // the groups they fall into. A group's id is its first face's.
            try db.execute(sql: """
                CREATE TABLE face_scan (
                    photoId INTEGER PRIMARY KEY NOT NULL REFERENCES photo(id) ON DELETE CASCADE,
                    versionPath TEXT NOT NULL,
                    modified DOUBLE NOT NULL,
                    rotation INTEGER,
                    scannedAt DOUBLE NOT NULL
                );
                CREATE TABLE face (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    photoId INTEGER NOT NULL REFERENCES photo(id) ON DELETE CASCADE,
                    kind TEXT NOT NULL,
                    x DOUBLE NOT NULL, y DOUBLE NOT NULL, w DOUBLE NOT NULL, h DOUBLE NOT NULL,
                    embedding BLOB NOT NULL,
                    groupId INTEGER
                );
                CREATE INDEX face_photoId ON face(photoId);
                CREATE INDEX face_groupId ON face(groupId);
                CREATE TABLE face_group (
                    id INTEGER PRIMARY KEY NOT NULL,
                    kind TEXT NOT NULL,
                    photoCount INTEGER NOT NULL,
                    coverFaceId INTEGER NOT NULL
                );
                """)
        }
        migrator.registerMigration("v10") { db in
            // The name given in People (from `.loupe/people.json`, set by each regrouping).
            try db.execute(sql: "ALTER TABLE face_group ADD COLUMN name TEXT")
        }
        migrator.registerMigration("v11") { db in
            // The name the photo's sidecar gives the face (people named in Apple Photos), set when it is scanned.
            try db.execute(sql: "ALTER TABLE face ADD COLUMN sourceName TEXT")
        }
        return migrator
    }

    static let rescanMarker = "rescan"

    /// `lastEditedAt` from what the index already holds, by the scanner's rule (`Scanner.lastEditedAt`): the newest
    /// edit version's mtime, or the sidecar's if it has LightCraft edits and is newer. Unchanged photos are not
    /// re-read by the next scan, so they get it here. Idempotent.
    static func fillLastEditedAt(_ db: Database) throws {
        try db.execute(sql: """
            UPDATE photo SET lastEditedAt = NULLIF(MAX(
                COALESCE((SELECT MAX(v.modified) FROM version v WHERE v.photoId = photo.id AND v.kind = 'edit'), -1e18),
                CASE WHEN hasLightCraftEdits = 1 AND sidecarModified IS NOT NULL THEN sidecarModified ELSE -1e18 END
            ), -1e18)
            """)
    }

    /// Photos with a sidecar are re-read on the next scan, so a `tiff:Orientation` written before v4 is picked up.
    /// No real fingerprint equals the marker (they all contain "@"), so the scanner sees those photos as changed.
    static func markSidecarPhotosForRescan(_ db: Database) throws {
        try db.execute(
            sql: "UPDATE photo SET legacySidecarFingerprint = ? WHERE sidecarModified IS NOT NULL OR legacySidecarFingerprint IS NOT NULL",
            arguments: [rescanMarker])
    }
}
