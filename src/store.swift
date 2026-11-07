// Private local storage: the event queue, send records and watcher state.
import Foundation
import SQLite3

let dataDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/wechat-adapter")

func ensureDataDir() throws {
    try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
}

struct Failure: Error {
    let reason: String
    init(_ reason: String) { self.reason = reason }
}

final class Store {
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init() throws {
        try ensureDataDir()
        let path = dataDir.appendingPathComponent("events.db").path
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw Failure("db_open_failed") }
        chmod(path, 0o600)
        sqlite3_busy_timeout(db, 5000)
        try run("""
        CREATE TABLE IF NOT EXISTS events(
          cursor INTEGER PRIMARY KEY AUTOINCREMENT, event_id TEXT NOT NULL, kind TEXT NOT NULL, chat_key TEXT NOT NULL,
          sender_display_name TEXT, is_self INTEGER, message_type TEXT, text TEXT,
          observed_at TEXT NOT NULL, displayed_time TEXT, reason TEXT)
        """)
        try run("""
        CREATE TABLE IF NOT EXISTS requests(
          request_id TEXT PRIMARY KEY, chat_key TEXT NOT NULL, status TEXT NOT NULL, reason TEXT,
          created_at TEXT NOT NULL, updated_at TEXT NOT NULL)
        """)
        try run("""
        CREATE TABLE IF NOT EXISTS messages(
          id INTEGER PRIMARY KEY, chat TEXT NOT NULL, pos INTEGER NOT NULL, key TEXT NOT NULL,
          sender TEXT, is_self INTEGER, type TEXT NOT NULL, text TEXT, image_path TEXT,
          displayed_time TEXT, sent_minute TEXT, captured_at TEXT NOT NULL, UNIQUE(chat, pos))
        """)
        _ = try? run("ALTER TABLE events ADD COLUMN image_path TEXT")  // fails harmlessly once added
        try run("DROP TABLE IF EXISTS chat_rows")
        try run("CREATE TABLE IF NOT EXISTS detached_windows(name TEXT PRIMARY KEY, used_at INTEGER NOT NULL)")
        try run("CREATE TABLE IF NOT EXISTS recent_rows(name TEXT PRIMARY KEY, position INTEGER NOT NULL, count INTEGER NOT NULL, checked_at INTEGER NOT NULL, used_at INTEGER NOT NULL)")
        try run("CREATE TABLE IF NOT EXISTS chat_state(chat_key TEXT PRIMARY KEY, row_hash TEXT NOT NULL, snapshot TEXT NOT NULL)")
    }

    @discardableResult
    func run(_ sql: String, _ args: [Any?] = []) throws -> [[String: Any]] {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { throw Failure("db_prepare_failed") }
        defer { sqlite3_finalize(st) }
        for (i, a) in args.enumerated() {
            let n = Int32(i + 1)
            switch a {
            case let s as String: sqlite3_bind_text(st, n, s, -1, transient)
            case let v as Int: sqlite3_bind_int64(st, n, Int64(v))
            case let b as Bool: sqlite3_bind_int64(st, n, b ? 1 : 0)
            default: sqlite3_bind_null(st, n)
            }
        }
        var rows: [[String: Any]] = []
        while true {
            let rc = sqlite3_step(st)
            if rc == SQLITE_DONE { return rows }
            guard rc == SQLITE_ROW else { throw Failure("db_step_failed") }
            var row: [String: Any] = [:]
            for c in 0..<sqlite3_column_count(st) {
                let name = String(cString: sqlite3_column_name(st, c))
                switch sqlite3_column_type(st, c) {
                case SQLITE_INTEGER: row[name] = Int(sqlite3_column_int64(st, c))
                case SQLITE_NULL: row[name] = NSNull()
                default: row[name] = String(cString: sqlite3_column_text(st, c))
                }
            }
            rows.append(row)
        }
    }

    var changes: Int { Int(sqlite3_changes(db)) }

    func transaction(_ body: () throws -> Void) throws {
        try run("BEGIN IMMEDIATE")
        do { try body(); try run("COMMIT") } catch { _ = try? run("ROLLBACK"); throw error }
    }

    func addMessage(_ m: Message, chat: String, imagePath: String?) throws {
        try run("""
        INSERT INTO events(event_id,kind,chat_key,sender_display_name,is_self,message_type,text,observed_at,displayed_time,image_path)
        VALUES(?,'message',?,?,?,?,?,?,?,?)
        """, [UUID().uuidString, chat, m.sender, m.isSelf, m.type, m.text, now(), m.displayedTime, imagePath])
    }

    /// Which messages in a window are missing from saved history, split by which end they belong to.
    func planHistory(_ chat: String, _ window: [Message]) throws -> (older: [Message], newer: [Message], aligned: Bool) {
        let existing = try run("SELECT key FROM messages WHERE chat=? ORDER BY pos", [chat]).compactMap { $0["key"] as? String }
        if existing.isEmpty { return (window, [], true) }
        guard let o = historyOffset(existing: existing, window: window.map(\.key)) else {
            // shortcut: with no alignment, a repeat of an already-saved message is dropped, upgrade if this gets common.
            let known = Set(existing)
            return ([], window.filter { !known.contains($0.key) }, false)
        }
        return (Array(window.prefix(max(0, -o))), Array(window.dropFirst(max(0, existing.count - o))), true)
    }

    /// Remembers the row of a recently used chat, keeping only the newest few.
    func rememberRow(_ name: String, position: Int, count: Int) throws {
        let time = Int(Date().timeIntervalSince1970)
        try run("INSERT OR REPLACE INTO recent_rows VALUES(?,?,?,?,?)", [name, position, count, time, time])
        try run("DELETE FROM recent_rows WHERE name NOT IN (SELECT name FROM recent_rows ORDER BY used_at DESC LIMIT 20)")
    }

    /// A remembered row, or nil if it's unknown or too old to trust for duplicate checks.
    func rowHint(_ name: String) throws -> (position: Int, count: Int)? {
        let oldest = Int(Date().timeIntervalSince1970) - 60
        guard let r = try run("SELECT position, count FROM recent_rows WHERE name=? AND checked_at>=?", [name, oldest]).first,
              let p = r["position"] as? Int, let c = r["count"] as? Int else { return nil }
        try run("UPDATE recent_rows SET used_at=? WHERE name=?", [Int(Date().timeIntervalSince1970), name])
        return (p, c)
    }

    /// watch already has every row, so it keeps the few remembered entries current. Only real changes are written.
    func refreshRecent(_ rows: [ChatRow], touch: Bool) throws {
        var position: [String: Int] = [:], count: [String: Int] = [:]
        for r in rows {
            let n = rowName(r.title)
            if position[n] == nil { position[n] = r.position }
            count[n, default: 0] += 1
        }
        let time = Int(Date().timeIntervalSince1970)
        for r in try run("SELECT name, position, count FROM recent_rows") {
            guard let n = r["name"] as? String else { continue }
            if let p = position[n], let c = count[n] {
                if p != r["position"] as? Int || c != r["count"] as? Int {
                    try run("UPDATE recent_rows SET position=?, count=?, checked_at=? WHERE name=?", [p, c, time, n])
                }
            } else {
                try run("DELETE FROM recent_rows WHERE name=?", [n])
            }
        }
        if touch { try run("UPDATE recent_rows SET checked_at=?", [time]) }
    }

    func touchWindow(_ name: String) throws {
        try run("INSERT OR REPLACE INTO detached_windows VALUES(?,?)", [name, Int(Date().timeIntervalSince1970)])
    }

    func windowUsage() throws -> [String: Int] {
        var used: [String: Int] = [:]
        for r in try run("SELECT name, used_at FROM detached_windows") {
            if let n = r["name"] as? String, let t = r["used_at"] as? Int { used[n] = t }
        }
        return used
    }

    func hasHistory(_ chat: String) throws -> Bool {
        try !run("SELECT 1 FROM messages WHERE chat=? LIMIT 1", [chat]).isEmpty
    }

    func saveHistory(_ chat: String, older: [Message], newer: [Message], paths: [Int: String]) throws {
        let range = try run("SELECT MIN(pos) lo, MAX(pos) hi FROM messages WHERE chat=?", [chat]).first
        let lo = range?["lo"] as? Int ?? 1, hi = range?["hi"] as? Int ?? 0
        func insert(_ m: Message, _ pos: Int) throws {
            try run("""
            INSERT INTO messages(chat,pos,key,sender,is_self,type,text,image_path,displayed_time,sent_minute,captured_at)
            VALUES(?,?,?,?,?,?,?,?,?,?,?)
            """, [chat, pos, m.key, m.sender, m.isSelf, m.type, m.text, paths[m.row], m.displayedTime, m.sentMinute, now()])
        }
        for (i, m) in older.enumerated() { try insert(m, lo - older.count + i) }
        for (i, m) in newer.enumerated() { try insert(m, hi + 1 + i) }
    }

    func addGap(chat: String, reason: String) throws {
        try run("INSERT INTO events(event_id,kind,chat_key,observed_at,reason) VALUES(?,'gap',?,?,?)",
                [UUID().uuidString, chat, now(), reason])
    }

    func state(_ chat: String) throws -> (rowHash: String, snapshot: [String])? {
        guard let r = try run("SELECT row_hash, snapshot FROM chat_state WHERE chat_key=?", [chat]).first,
              let h = r["row_hash"] as? String, let s = r["snapshot"] as? String else { return nil }
        return (h, s.isEmpty ? [] : s.components(separatedBy: ","))
    }

    func saveState(_ chat: String, rowHash: String, snapshot: [String]) throws {
        try run("INSERT OR REPLACE INTO chat_state VALUES(?,?,?)", [chat, rowHash, snapshot.joined(separator: ",")])
    }
}

let sharedStore = try? Store()

func now() -> String { ISO8601DateFormatter().string(from: Date()) }
