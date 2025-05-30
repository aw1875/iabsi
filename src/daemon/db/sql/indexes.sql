CREATE INDEX IF NOT EXISTS idx_files_path ON files(path);
CREATE INDEX IF NOT EXISTS idx_files_modified ON files(modified);
CREATE INDEX IF NOT EXISTS idx_files_backup_status ON files(backup_status);
CREATE INDEX IF NOT EXISTS idx_files_last_scan_time ON files(last_scan_time);
