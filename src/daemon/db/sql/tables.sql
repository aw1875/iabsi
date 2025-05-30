CREATE TABLE IF NOT EXISTS files (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    path TEXT UNIQUE NOT NULL,
    size INTEGER NOT NULL,
    modified INTEGER NOT NULL,
    file_hash BLOB,
    backup_status TEXT NOT NULL DEFAULT 'needs_backup', -- needs_backup, backing_up, backed_up, backup_failed, backup_skipped
    last_scan_time INTEGER,
    last_backup_time INTEGER,
    backup_error TEXT,
    created_at INTEGER DEFAULT (strftime('%s', 'now')),
    updated_at INTEGER DEFAULT (strftime('%s', 'now'))
);
