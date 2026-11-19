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
        return migrator
    }

    static let rescanMarker = "rescan"

    /// Photos with a sidecar are re-read on the next scan, so a `tiff:Orientation` written before v4 is picked up.
    /// No real fingerprint equals the marker (they all contain "@"), so the scanner sees those photos as changed.
    static func markSidecarPhotosForRescan(_ db: Database) throws {
        try db.execute(
            sql: "UPDATE photo SET legacySidecarFingerprint = ? WHERE sidecarModified IS NOT NULL OR legacySidecarFingerprint IS NOT NULL",
            arguments: [rescanMarker])
    }
}
