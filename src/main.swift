// wechat-cli: local CLI for any chat in the logged-in WeChat client. JSON on stdout, diagnostics on stderr.
import AppKit
import Foundation

func emit(_ object: [String: Any?]) {
    let clean = object.mapValues { $0 ?? NSNull() }
    guard let d = try? JSONSerialization.data(withJSONObject: clean, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
    FileHandle.standardOutput.write(d + Data("\n".utf8))
}

func log(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

func flag(_ name: String) -> String? {
    let args = CommandLine.arguments
    return args.firstIndex(of: "--" + name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
}

func required(_ name: String) throws -> String {
    guard let v = flag(name), !v.isEmpty else { throw Failure("missing_--\(name)") }
    return v
}

/// Every UI operation runs under this lock, across processes. Waiters refresh a marker file,
/// and background work stays out while the marker is fresh, so send and watch always go first.
func withUILock<T>(background: Bool = false, _ body: () throws -> T) throws -> T {
    try ensureDataDir()
    let fd = open(dataDir.appendingPathComponent("ui.lock").path, O_CREAT | O_RDWR, 0o600)
    guard fd >= 0 else { throw Failure("lock_failed") }
    defer { close(fd) }
    let marker = dataDir.appendingPathComponent("ui.waiting").path
    func someoneWaiting() -> Bool {
        let at = (try? FileManager.default.attributesOfItem(atPath: marker))?[.modificationDate] as? Date
        return at.map { Date().timeIntervalSince($0) < 0.5 } ?? false
    }
    let deadline = Date().addingTimeInterval(background ? 600 : 20)
    while (background && someoneWaiting()) || flock(fd, LOCK_EX | LOCK_NB) != 0 {
        if Date() > deadline { throw Failure("ui_busy") }
        if !background { FileManager.default.createFile(atPath: marker, contents: nil, attributes: [.posixPermissions: 0o600]) }
        Thread.sleep(forTimeInterval: 0.1)
    }
    return try body()
}

/// The keyboard, mouse and clipboard are shared by every window, so anything using them takes turns here.
/// It's only held briefly, and watch's normal reads never need it. Lock order is always UI first, then focus.
func withFocusLock<T>(_ body: () throws -> T) throws -> T {
    try ensureDataDir()
    let fd = open(dataDir.appendingPathComponent("focus.lock").path, O_CREAT | O_RDWR, 0o600)
    guard fd >= 0 else { throw Failure("lock_failed") }
    defer { close(fd) }
    let deadline = Date().addingTimeInterval(20)
    while flock(fd, LOCK_EX | LOCK_NB) != 0 {
        if Date() > deadline { throw Failure("focus_busy") }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return try body()
}

let maxDetachedWindows = 5

/// Makes room by closing the least recently used window. A window with a draft, or one used in the
/// last 10 seconds, is never closed.
func evictDetachedWindows() throws {
    while true {
        let open = wechatWindows().filter { !isMainWindow($0) && str($0, kAXTitleAttribute)?.hasSuffix("(Window)") == true }
        guard open.count >= maxDetachedWindows else { return }
        let used = (try? sharedStore?.windowUsage()) ?? [:]
        let now = Int(Date().timeIntervalSince1970)
        let candidates = open.compactMap { w -> (AXUIElement, Int)? in
            let last = used[detachedChatName(str(w, kAXTitleAttribute) ?? "")] ?? 0
            let draft = firstInput(w).flatMap { str($0, kAXValueAttribute) } ?? ""
            return draft.isEmpty && now - last >= 10 ? (w, last) : nil
        }
        guard let oldest = candidates.min(by: { $0.1 < $1.1 }), let close = attr(oldest.0, kAXCloseButtonAttribute) else {
            throw Failure("too_many_detached_windows")
        }
        AXUIElementPerformAction(close as! AXUIElement, kAXPressAction as CFString)
        Thread.sleep(forTimeInterval: 0.3)
    }
}

/// Reuses the chat's detached window, or opens one. Only opening needs the main window.
func ensureDetached(_ name: String) throws {
    if (try? UI.detached(name)) == nil {
        try withUILock {
            try evictDetachedWindows()
            try detachChat(name)
        }
    }
    try? sharedStore?.touchWindow(name)
}

func status() {
    var state = "ready"
    var active: String?
    do { active = try UI.locate(reopen: false).activeChat } catch { state = (error as? Failure)?.reason ?? "unknown_error" }
    if state == "logged_out" { log("it's logged out") }
    let version = wechatVersion()
    emit(["state": state, "ready": state == "ready", "wechat_running": wechatApp() != nil, "wechat_version": version,
          "version_tested": version.map(testedVersions.contains), "accessibility_granted": AXIsProcessTrusted(),
          "screen_locked": screenLocked(), "active_chat": active])
}

func listChats() throws {
    for r in try withUILock({ try UI.locate().rows() }) { emit(["name": rowName(r.title)]) }
}

func read() throws {
    let name = try required("chat")
    let limit = Int(flag("limit") ?? "20") ?? 20
    guard limit > 0 else { throw Failure("bad_--limit") }
    let (messages, bottom): ([Message], Bool) = try withUILock {
        let (ui, cells) = try openChat(name)
        return (parseMessages(cells), ui.atBottom)
    }
    let recent = messages.suffix(limit)
    let observed = now()
    emit(["chat_key": name, "returned": recent.count, "loaded": messages.count, "at_bottom": bottom,
          "complete": bottom && recent.count == limit,
          "messages": recent.map { m -> [String: Any] in
              // event_id is null because a read is not a queue event.
              ["event_id": NSNull(), "chat_key": name, "sender_display_name": m.sender ?? NSNull(), "is_self": m.isSelf ?? NSNull(),
               "message_type": m.type, "text": m.text ?? NSNull(), "observed_at": observed, "displayed_time": m.displayedTime ?? NSNull()]
          }])
}

func send() throws {
    let requestID = try required("request-id"), name = try required("chat"), text = try required("text")
    let store = try Store()
    try store.run("INSERT OR IGNORE INTO requests VALUES(?,?,'pending',NULL,?,?)", [requestID, name, now(), now()])
    if store.changes == 0 {
        let first = try store.run("SELECT status, reason FROM requests WHERE request_id=?", [requestID]).first
        emit(["request_id": requestID, "chat_key": name, "status": "duplicate_request",
              "original_status": first?["status"], "reason": first?["reason"] as? String])
        return
    }
    func finish(_ status: String, _ reason: String?) throws {
        try store.run("UPDATE requests SET status=?, reason=?, updated_at=? WHERE request_id=?", [status, reason, now(), requestID])
        emit(["request_id": requestID, "chat_key": name, "status": status, "reason": reason])
    }
    do {
        try ensureDetached(name)
        let (status, reason) = try withFocusLock { try submit(name, text, store, requestID) }
        try finish(status, reason)
    } catch {
        try finish("failed", (error as? Failure)?.reason ?? "unknown_error")
    }
}

/// Sends from the chat's detached window, so the main window is never touched.
/// Everything before Return can fail safely. After Return the only honest outcomes are confirmed or unknown.
func submit(_ name: String, _ text: String, _ store: Store, _ requestID: String) throws -> (String, String?) {
    let started = Date()
    let ui = try UI.detached(name)
    guard ui.activeChat == name else { return ("failed", "chat_changed") }
    guard let draft = ui.inputValue else { return ("failed", "input_unreadable") }
    if !draft.isEmpty {
        guard ui.setInput("") else { return ("failed", "draft_not_cleared") }
    }
    // An unsent draft is set aside for the send, then put back, so it never blocks a send or gets lost.
    defer {
        if !draft.isEmpty {
            let restored = try? UI.detached(name)
            if restored?.inputValue?.isEmpty != true || restored?.setInput(draft) != true { log("draft not restored") }
        }
    }
    let baseline = parseMessages(ui.cells()).map(\.key)
    guard ui.setInput(text) else {
        if ui.inputValue == text { _ = ui.setInput("") }
        return ("failed", "input_not_writable")
    }
    let current = try UI.detached(name)
    let elapsed = Date().timeIntervalSince(started)
    guard current.activeChat == name, !humanActive(within: elapsed) else {
        let reason = current.activeChat == name ? "interrupted" : "chat_changed"
        if current.inputValue == text { _ = current.setInput("") }
        return ("failed", reason)
    }
    guard current.focusInput() else {
        if current.inputValue == text { _ = current.setInput("") }
        return ("failed", "input_not_focused")
    }
    // Recorded first, so a crash after Return can never look like a safe retry.
    try store.run("UPDATE requests SET status='submitting', updated_at=? WHERE request_id=?", [now(), requestID])
    current.pressReturn()
    for _ in 0..<25 {
        Thread.sleep(forTimeInterval: 0.2)
        guard let ui = try? UI.detached(name), ui.activeChat == name else { continue }
        let messages = parseMessages(ui.cells())
        if let start = unseenStart(old: baseline, new: messages.map(\.key)),
           messages[start...].contains(where: { $0.isSelf == true && $0.type == "text" && $0.text == text }) {
            return ("local_echo_confirmed", nil)
        }
    }
    if let ui = try? UI.detached(name), ui.activeChat == name, ui.inputValue == text {
        _ = ui.setInput("")
        return ("failed", "return_not_accepted")
    }
    return ("unknown", "no_local_echo")
}

func saveImages(_ messages: [Message], cells: [Cell], ui: UI) -> [Int: String] {
    let titles = Dictionary(cells.map { ($0.row, $0.title) }, uniquingKeysWith: { a, _ in a })
    var paths: [Int: String] = [:]
    for m in messages where m.type == "image" {
        // Each image takes its own short turn, because the viewer uses the clipboard and keyboard.
        if let title = titles[m.row], let path = try? withFocusLock({ ui.saveImage(m, title: title) }) { paths[m.row] = path }
    }
    return paths
}

func backfill() throws {
    let lastFlag = flag("last") ?? "100"
    let last = lastFlag == "all" ? nil : Int(lastFlag)
    guard lastFlag == "all" || (last ?? 0) > 0 else { throw Failure("bad_--last") }
    let detached = CommandLine.arguments.contains("--detached")
    let names: [String]
    if detached && flag("chat") == nil { throw Failure("--detached_needs_--chat") }
    if let chat = flag("chat") {
        names = [chat]
    } else {
        guard let count = Int(flag("chats") ?? ""), count > 0 else { throw Failure("missing_--chats_or_--chat") }
        names = try withUILock { Array(try UI.locate().rows().prefix(count).map { rowName($0.title) }) }
    }
    let store = try Store()
    for name in names {
        do {
            emit(try backfillChat(name, last: last, store: store, detached: detached))
        } catch {
            emit(["chat": name, "status": "failed", "reason": (error as? Failure)?.reason ?? "unknown_error"])
        }
    }
}

/// Works in short turns, one scroll or one small batch per lock, so send and watch never wait long.
/// Saved progress survives if they switch chats. Only the scrolling has to be repeated.
/// With `detached`, it works in that chat's own window and never takes the UI lock.
func backfillChat(_ name: String, last: Int?, store: Store, detached: Bool = false) throws -> [String: Any?] {
    var saved = 0, images = 0, failed = 0, stalled = 0
    var aligned = true, reachedTop = false, done = false, opened = false
    if detached { try ensureDetached(name) }
    while !done {
        func turn() throws {
                var ui: UI
                if detached {
                    ui = try UI.detached(name)
                    try? sharedStore?.touchWindow(name)
                } else {
                    ui = try UI.locate()
                    if !opened || ui.activeChat != name {
                        ui = try openChat(name).ui
                        opened = true
                    }
                }
                let cells = ui.cells()
                let all = parseMessages(cells)
                var window = last.map { Array(all.suffix($0)) } ?? all
                // A message whose time label isn't loaded yet waits for the next scroll, unless this is the top.
                if !reachedTop { window = Array(window.drop { $0.displayedTime == nil }) }

                let plan = try store.planHistory(name, window)
                aligned = aligned && plan.aligned
                if !plan.older.isEmpty || !plan.newer.isEmpty {
                    let older = newestBatch(plan.older, maxImages: 1)
                    let batch = older + plan.newer
                    let paths = saveImages(batch, cells: cells, ui: ui)
                    try store.transaction { try store.saveHistory(name, older: older, newer: plan.newer, paths: paths) }
                    saved += batch.count
                    images += paths.count
                    failed += batch.filter { $0.type == "image" }.count - paths.count
                    return
                }
                if reachedTop || last.map({ window.count >= $0 }) == true {
                    ui.scroll(to: 1)
                    done = true
                    return
                }
                ui.scroll(to: 0)
                Thread.sleep(forTimeInterval: 1.2)
                stalled = ui.cells().count > cells.count ? 0 : stalled + 1
                if stalled >= 3 { reachedTop = true }
        }
        try autoreleasepool {
            if detached { try turn() } else { try withUILock(background: true, turn) }
        }
        if !done { Thread.sleep(forTimeInterval: 0.3) }  // lets a waiting send or watch take the lock
    }
    return ["chat": name, "status": "ok", "saved": saved, "images_saved": images, "images_failed": failed,
            "aligned": aligned, "reached_top": reachedTop]
}

func export() throws {
    let out = URL(fileURLWithPath: try required("out"), isDirectory: true)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let store = try Store()
    func field(_ value: Any?) -> String {
        var s = value as? String ?? (value as? Int).map(String.init) ?? ""
        if let first = s.first, "=+-@".contains(first) { s = "'" + s }  // stops spreadsheets running a message as a formula
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    let columns = ["chat", "sender", "is_self", "type", "sent_minute", "displayed_time", "text", "image_path"]
    for row in try store.run("SELECT DISTINCT chat FROM messages ORDER BY chat") {
        guard let chat = row["chat"] as? String else { continue }
        var csv = "\u{FEFF}" + columns.joined(separator: ",") + "\n"  // the BOM makes Excel read Chinese correctly
        let rows = try store.run("SELECT \(columns.joined(separator: ",")) FROM messages WHERE chat=? ORDER BY pos", [chat])
        for r in rows {
            var row = r
            row["image_path"] = absoluteImage(r["image_path"])
            csv += columns.map { field(row[$0]) }.joined(separator: ",") + "\n"
        }
        let safe = chat.replacingOccurrences(of: #"[/:\\]"#, with: "_", options: .regularExpression)
        let name = (safe == chat ? safe : safe + "-" + sha(chat).prefix(8)) + ".csv"
        let url = out.appendingPathComponent(name)
        guard FileManager.default.createFile(atPath: url.path, contents: Data(csv.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw Failure("export_write_failed")
        }
        emit(["chat": chat, "messages": rows.count, "file": url.path])
    }
}

func eventRows(_ store: Store, after: Int, limit: Int) throws -> [[String: Any]] {
    try store.run("SELECT * FROM events WHERE cursor>? ORDER BY cursor LIMIT ?", [after, limit]).map { row in
        var e = row
        if let s = e["is_self"] as? Int { e["is_self"] = s == 1 }
        e["image_path"] = absoluteImage(e["image_path"])
        return e
    }
}

func events() throws {
    let after = Int(flag("after") ?? "0") ?? 0
    let limit = Int(flag("limit") ?? "1000") ?? 1000
    let store = try Store()
    if CommandLine.arguments.contains("--latest") {
        emit(["cursor": try store.run("SELECT COALESCE(MAX(cursor), 0) c FROM events").first?["c"]])
        return
    }
    guard CommandLine.arguments.contains("--follow") else {
        for e in try eventRows(store, after: after, limit: limit) { emit(e) }
        return
    }
    // Sleeps until watch commits new rows, with no polling. Registered before the first read, so nothing is missed.
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, _, _, _ in followWake.signal() },
                                    eventsNotification as CFString, nil, .deliverImmediately)
    let start = after
    Thread.detachNewThread {
        var cursor = start
        while true {
            autoreleasepool {
                guard let rows = try? eventRows(store, after: cursor, limit: limit) else { exit(1) }
                for e in rows {
                    emit(e)
                    cursor = e["cursor"] as? Int ?? cursor
                }
            }
            followWake.wait()
        }
    }
    CFRunLoopRun()
}

let followWake = DispatchSemaphore(value: 0)

func messageOutput(_ row: [String: Any]) -> [String: Any] {
    var m = row
    if let s = m["is_self"] as? Int { m["is_self"] = s == 1 }
    m["image_path"] = absoluteImage(m["image_path"])
    return m
}

let messageColumns = "chat, sender, is_self, type, text, image_path, displayed_time, sent_minute"

/// Saved history for one chat, oldest first, from SQLite only.
func history() throws {
    let name = try required("chat")
    let limit = Int(flag("limit") ?? "100") ?? 100
    let rows = try Store().run("""
    SELECT \(messageColumns) FROM (SELECT * FROM messages WHERE chat=? ORDER BY pos DESC LIMIT ?) ORDER BY pos
    """, [name, limit])
    for r in rows { emit(messageOutput(r)) }
}

/// Finds saved messages by text, newest first, from SQLite only.
func search() throws {
    let query = try required("query")
    let limit = Int(flag("limit") ?? "50") ?? 50
    let rows: [[String: Any]]
    if let chat = flag("chat") {
        rows = try Store().run("SELECT \(messageColumns) FROM messages WHERE chat=? AND instr(text, ?)>0 ORDER BY pos DESC LIMIT ?", [chat, query, limit])
    } else {
        rows = try Store().run("SELECT \(messageColumns) FROM messages WHERE instr(text, ?)>0 ORDER BY id DESC LIMIT ?", [query, limit])
    }
    for r in rows { emit(messageOutput(r)) }
}

let allChats = "*"  // chat_key of a gap that affects every chat

final class Watcher {
    let store: Store
    let interval: TimeInterval
    let sweepEvery: TimeInterval = 60    // identical previews in the same minute leave the row unchanged
    let recentWindow: TimeInterval = 600 // only recently active chats are swept, to avoid reopening every chat
    let maxChanges = 10                  // more than this in one tick is a relabel, such as dates rolling over
    var lastSweep = Date.distantPast
    var lastRefresh = Date.distantPast
    var lastTick = Date()
    var down: String?
    var gapped: [String: String] = [:]
    var seen: [String: String]?          // row hash by chat name, nil until the first tick
    var active: [String: Date] = [:]
    var debugTitles: [String: String] = [:]
    let debugLog: FileHandle?            // --debug-rows: row changes, holds chat previews

    init(store: Store, interval: TimeInterval, debugLog: FileHandle?) {
        self.store = store
        self.interval = interval
        self.debugLog = debugLog
    }

    func debug(_ object: [String: Any]) {
        guard let debugLog, let d = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        debugLog.write(d + Data("\n".utf8))
    }

    func gap(_ chat: String, _ reason: String) throws {
        guard gapped[chat] != reason else { return }  // once per outage
        gapped[chat] = reason
        try store.addGap(chat: chat, reason: reason)
        log("gap: \(reason)")
    }

    func start() throws {
        if try !store.run("SELECT 1 FROM chat_state LIMIT 1").isEmpty {
            try store.addGap(chat: allChats, reason: "watcher_restart")
        }
        while true {
            // A loop that never returns must drain its own pool, or every tick's objects stay in memory.
            do { try autoreleasepool { try withUILock(tick) } } catch let f as Failure where f.reason == "ui_busy" { log("ui busy, retrying") }
            Thread.sleep(forTimeInterval: interval)
        }
    }

    func tick() throws {
        let time = Date()
        if time.timeIntervalSince(lastTick) > max(30, interval * 5) {
            try store.addGap(chat: allChats, reason: "watcher_paused")
        }
        lastTick = time

        let ui: UI
        let rows: [ChatRow]
        do {
            ui = try UI.locate()
            rows = ui.rows()
            if rows.isEmpty { throw Failure("chat_list_unreadable") }
        } catch let f as Failure {
            if down != f.reason { log(f.reason == "logged_out" ? "it's logged out" : "ui unavailable: \(f.reason)") }
            down = f.reason
            try gap(allChats, f.reason)
            return
        }
        if down != nil { log("ui available again") }
        down = nil
        gapped[allChats] = nil

        let touch = time.timeIntervalSince(lastRefresh) >= 30
        if touch { lastRefresh = time }
        try store.refreshRecent(rows, touch: touch)
        let current = Dictionary(rows.map { (rowName($0.title), rowFingerprint($0.title)) }, uniquingKeysWith: { a, _ in a })
        let titles = Dictionary(rows.map { (rowName($0.title), $0.title) }, uniquingKeysWith: { a, _ in a })
        defer { debugTitles = titles }
        if debugLog != nil && seen == nil {
            debug(["at": now(), "first_rows": rows.prefix(20).map(\.title), "rows": rows.count, "unique_names": current.count])
        }
        guard let previous = seen else {
            // First tick: only chats captured before can be compared. Others start from their current row.
            seen = current
            let open = ui.activeChat
            for (name, hash) in current {
                let saved = try store.state(name)
                if name == open || (saved != nil && saved?.rowHash != hash) {
                    try captureSafely(name, rowHash: hash, firstSeenByChange: false)
                }
            }
            return
        }

        let changed = current.filter { previous[$0.key] != $0.value }
        if debugLog != nil && !changed.isEmpty {
            debug(["at": now(), "changed": changed.count, "mass": changed.count > maxChanges, "rows": rows.count, "unique_names": current.count,
                   "changes": changed.keys.prefix(20).map { ["before": debugTitles[$0] ?? "(not seen)", "after": titles[$0] ?? ""] }])
        }
        if changed.count > maxChanges {
            // shortcut: a real burst across this many chats is skipped too, upgrade by stripping the time from row labels.
            seen = current
            try store.addGap(chat: allChats, reason: "mass_row_change")
            return
        }
        for (name, hash) in changed {
            if name != ui.activeChat && humanActive(within: 3) { continue }  // stays changed, retried next tick
            seen?[name] = hash
            active[name] = time
            try captureSafely(name, rowHash: hash, firstSeenByChange: true)
        }

        if let open = ui.activeChat, changed[open] == nil, let hash = current[open] {
            try captureSafely(open, rowHash: hash, firstSeenByChange: false)
        }
        if time.timeIntervalSince(lastSweep) >= sweepEvery {
            lastSweep = time
            active = active.filter { time.timeIntervalSince($0.value) < recentWindow }
            for name in active.keys where changed[name] == nil && name != ui.activeChat && !humanActive(within: 3) {
                if let hash = current[name] { try captureSafely(name, rowHash: hash, firstSeenByChange: false) }
            }
        }
    }

    func captureSafely(_ name: String, rowHash: String, firstSeenByChange: Bool) throws {
        do {
            try capture(name, rowHash: rowHash, firstSeenByChange: firstSeenByChange)
            gapped[name] = nil
        } catch let f as Failure {
            try gap(name, f.reason)
        }
    }

    func capture(_ name: String, rowHash: String, firstSeenByChange: Bool) throws {
        let (ui, cells) = try openChat(name, tail: 60)  // more than a chat loads on open, so overlap stays intact
        let messages = parseMessages(cells)
        let keys = messages.map(\.key)
        let saved = try store.state(name)?.snapshot

        var fresh: [Message] = []
        var gapReason: String?
        if let saved {
            if let start = unseenStart(old: saved, new: keys) {
                fresh = Array(messages[start...])
            } else {
                // shortcut: a recalled message in the middle also lands here, upgrade to partial alignment if gaps are noisy.
                gapReason = "no_overlap"
            }
        } else if firstSeenByChange, let newest = messages.last {
            // With no snapshot, only the newest message is known to be new. Others may have arrived with it.
            gapReason = "first_seen"
            fresh = [newest]
        }

        // watch only adds new messages. Older rows belong to backfill, which also saves their images.
        let newer = try store.hasHistory(name) ? store.planHistory(name, messages).newer : fresh
        let paths = saveImages(fresh, cells: cells, ui: ui)
        try store.transaction {
            if let gapReason { try store.addGap(chat: name, reason: gapReason) }
            for m in fresh { try store.addMessage(m, chat: name, imagePath: paths[m.row]) }
            try store.saveHistory(name, older: [], newer: newer, paths: paths)
            try store.saveState(name, rowHash: rowHash, snapshot: keys)
        }
    }
}

func watch() throws {
    try ensureDataDir()
    let fd = open(dataDir.appendingPathComponent("watch.lock").path, O_CREAT | O_RDWR, 0o600)
    guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw Failure("watch_already_running") }
    let interval = Double(flag("interval") ?? "2") ?? 2
    guard interval >= 0.5 else { throw Failure("bad_--interval") }
    var debugLog: FileHandle?
    if CommandLine.arguments.contains("--debug-rows") {
        let path = dataDir.appendingPathComponent("rows-debug.jsonl").path
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        debugLog = FileHandle(forWritingAtPath: path)
        debugLog?.seekToEndOfFile()
    }
    try Watcher(store: try Store(), interval: interval, debugLog: debugLog).start()
}

do {
    switch CommandLine.arguments.dropFirst().first {
    case "start":
        _ = try? UI.locate()  // launches WeChat or reopens its window, and status reports the outcome
        status()
    case "status": status()
    case "chats": try listChats()
    case "read": try read()
    case "send": try send()
    case "watch": try watch()
    case "events": try events()
    case "backfill": try backfill()
    case "history": try history()
    case "search": try search()
    case "windows":
        for w in wechatWindows() {
            let main = isMainWindow(w)
            emit(["window": main ? "main" : "detached", "chat": main ? nil : detachedChatName(str(w, kAXTitleAttribute) ?? "")])
        }
    case "detach":
        let name = try required("chat")
        try ensureDetached(name)
        emit(["chat": name, "status": "detached"])
    case "export": try export()
    case "selftest": selftest(); log("selftest passed")
    default:
        log("usage: wechat-cli start|status|chats|read|send|watch|events|history|search|backfill|export|windows|detach")
        exit(64)
    }
} catch {
    let reason = (error as? Failure)?.reason ?? "unknown_error"
    if reason == "logged_out" { log("it's logged out") }
    emit(["error": reason])
    exit(1)
}
