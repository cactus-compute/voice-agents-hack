-- Ali laptop-wide disk index
-- One SQLite file holds file metadata, text chunks, and an FTS5 full-text index.
-- Vector embeddings live outside SQLite in `vectors.bin` (hnswlib) because
-- hnswlib is an order of magnitude faster for cosine top-k than any sqlite
-- vector extension we can rely on shipping.

PRAGMA journal_mode = WAL;
PRAGMA synchronous  = NORMAL;
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS files (
    id          INTEGER PRIMARY KEY,
    path        TEXT    NOT NULL UNIQUE,
    name        TEXT    NOT NULL,
    ext         TEXT,
    size        INTEGER,
    mtime       REAL,
    mime        TEXT,
    indexed_at  REAL    NOT NULL,
    content_ok  INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_files_name ON files(name);
CREATE INDEX IF NOT EXISTS idx_files_ext  ON files(ext);

CREATE TABLE IF NOT EXISTS chunks (
    id          INTEGER PRIMARY KEY,
    file_id     INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
    chunk_idx   INTEGER NOT NULL,
    text        TEXT    NOT NULL,
    -- `vector` stores the sentence-transformer embedding as a float32 BLOB.
    -- NULL = not yet embedded. Lets us resume an interrupted build and
    -- re-embed only missing chunks.
    vector      BLOB,
    UNIQUE(file_id, chunk_idx)
);

CREATE INDEX IF NOT EXISTS idx_chunks_file   ON chunks(file_id);
CREATE INDEX IF NOT EXISTS idx_chunks_novec  ON chunks(id) WHERE vector IS NULL;

-- Full-text search across chunk bodies, with the file basename included so
-- "find stripe contract" matches both filename and content hits.
CREATE VIRTUAL TABLE IF NOT EXISTS content_fts USING fts5(
    name,
    text,
    content='chunks',
    content_rowid='id',
    tokenize='porter unicode61 remove_diacritics 2'
);

CREATE TRIGGER IF NOT EXISTS chunks_ai AFTER INSERT ON chunks BEGIN
    INSERT INTO content_fts(rowid, name, text)
    SELECT new.id, files.name, new.text
    FROM files WHERE files.id = new.file_id;
END;

CREATE TRIGGER IF NOT EXISTS chunks_ad AFTER DELETE ON chunks BEGIN
    INSERT INTO content_fts(content_fts, rowid, name, text)
    VALUES('delete', old.id,
           (SELECT name FROM files WHERE id = old.file_id),
           old.text);
END;

CREATE TABLE IF NOT EXISTS manifest (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
