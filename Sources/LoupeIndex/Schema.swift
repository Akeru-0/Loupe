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
        return migrator
    }
}
