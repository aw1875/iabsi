CREATE TRIGGER IF NOT EXISTS update_files_updated_at
    AFTER UPDATE ON files
BEGIN
    UPDATE files SET updated_at = strftime('%s', 'now') WHERE id = NEW.id;
END;
