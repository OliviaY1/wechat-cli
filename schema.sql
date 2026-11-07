CREATE TABLE events(
  cursor INTEGER PRIMARY KEY AUTOINCREMENT, event_id TEXT NOT NULL, kind TEXT NOT NULL, chat_key TEXT NOT NULL,
  sender_display_name TEXT, is_self INTEGER, message_type TEXT, text TEXT,
  observed_at TEXT NOT NULL, displayed_time TEXT, reason TEXT, image_path TEXT);
CREATE TABLE requests(
  request_id TEXT PRIMARY KEY, chat_key TEXT NOT NULL, status TEXT NOT NULL, reason TEXT,
  created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
CREATE TABLE chat_state(chat_key TEXT PRIMARY KEY, row_hash TEXT NOT NULL, snapshot TEXT NOT NULL);
CREATE TABLE messages(
  id INTEGER PRIMARY KEY, chat TEXT NOT NULL, pos INTEGER NOT NULL, key TEXT NOT NULL,
  sender TEXT, is_self INTEGER, type TEXT NOT NULL, text TEXT, image_path TEXT,
  displayed_time TEXT, sent_minute TEXT, captured_at TEXT NOT NULL, UNIQUE(chat, pos));
CREATE TABLE recent_rows(name TEXT PRIMARY KEY, position INTEGER NOT NULL, count INTEGER NOT NULL, checked_at INTEGER NOT NULL, used_at INTEGER NOT NULL);
CREATE TABLE detached_windows(name TEXT PRIMARY KEY, used_at INTEGER NOT NULL);
