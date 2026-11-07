// The only file that touches WeChat's accessibility tree. Tested on WeChat 3.8.10 with the English UI.
import AppKit
import ApplicationServices

let bundleID = "com.tencent.xinWeChat"
let testedVersions = ["3.8.10"]

func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
}
func str(_ e: AXUIElement, _ name: String) -> String? { attr(e, name) as? String }
func list(_ e: AXUIElement, _ name: String) -> [AXUIElement] { attr(e, name) as? [AXUIElement] ?? [] }
func children(_ e: AXUIElement) -> [AXUIElement] { list(e, kAXChildrenAttribute) }
func role(_ e: AXUIElement) -> String { str(e, kAXRoleAttribute) ?? "" }

func wechatApp() -> NSRunningApplication? {
    NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
}

func wechatVersion() -> String? {
    wechatApp()?.bundleURL.flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String }
}

func screenLocked() -> Bool {
    (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
}

/// True if a key press or click happened in the last `seconds`. Mouse movement does not count.
func humanActive(within seconds: TimeInterval) -> Bool {
    [CGEventType.keyDown, .leftMouseDown, .rightMouseDown].contains {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) < seconds
    }
}

struct ChatRow {
    let row: AXUIElement
    let title: String
    let position: Int
}

func isMainWindow(_ w: AXUIElement) -> Bool { children(w).contains { role($0) == "AXRadioButton" } }

func wechatWindows() -> [AXUIElement] {
    guard let app = wechatApp() else { return [] }
    let ax = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(ax, 3)
    return list(ax, kAXWindowsAttribute)
}

func firstTable(_ e: AXUIElement, depth: Int = 0) -> AXUIElement? {
    if role(e) == "AXTable" { return e }
    guard depth < 8 else { return nil }
    return children(e).lazy.compactMap { firstTable($0, depth: depth + 1) }.first
}

func firstInput(_ e: AXUIElement, depth: Int = 0) -> AXUIElement? {
    if role(e) == "AXTextArea", str(e, kAXTitleAttribute)?.isEmpty == false { return e }
    guard depth < 8, role(e) != "AXTable" else { return nil }
    return children(e).lazy.compactMap { firstInput($0, depth: depth + 1) }.first
}

struct UI {
    let pid: pid_t
    let window: AXUIElement
    let chatList: AXUIElement
    let messages: AXUIElement?
    let header: AXUIElement?
    let input: AXUIElement?

    /// Reopens a closed window or a quit app, because the adapter has to run unattended.
    static func locate(reopen: Bool = true) throws -> UI {
        do {
            return try find()
        } catch let f as Failure where reopen && (f.reason == "no_window" || f.reason == "wechat_not_running") {
            log("\(f.reason): reopening WeChat")
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = ["-b", bundleID]
            try? open.run()
            open.waitUntilExit()
            for _ in 0..<25 {
                Thread.sleep(forTimeInterval: 0.4)
                if let ui = try? find() { return ui }
            }
            return try find()
        }
    }

    /// Finds the main window's parts by structure, because the _NS ids change between builds.
    private static func find() throws -> UI {
        guard AXIsProcessTrusted() else { throw Failure("accessibility_not_granted") }
        guard let app = wechatApp() else { throw Failure("wechat_not_running") }
        if screenLocked() { throw Failure("screen_locked") }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 3)
        let windows = list(ax, kAXWindowsAttribute)
        if windows.isEmpty { throw Failure("no_window") }
        var sawTabs = false
        var sawChat = false
        for w in windows {
            sawChat = sawChat || (!isMainWindow(w) && firstTable(w) != nil)
            let kids = children(w)
            sawTabs = sawTabs || kids.contains { role($0) == "AXRadioButton" }
            guard let split = kids.first(where: { role($0) == "AXSplitGroup" }) else { continue }
            let parts = children(split)
            guard let table = parts.first(where: { role($0) == "AXScrollArea" }).flatMap({ children($0).first { role($0) == "AXTable" } }),
                  isChatList(table) else { continue }
            let inner = parts.first { role($0) == "AXSplitGroup" }.map(children) ?? []
            let areas = inner.filter { role($0) == "AXScrollArea" }
            return UI(pid: app.processIdentifier, window: w, chatList: table,
                      messages: areas.lazy.compactMap { children($0).first { role($0) == "AXTable" } }.first,
                      header: inner.first { role($0) == "AXStaticText" },
                      input: areas.lazy.compactMap { children($0).first { role($0) == "AXTextArea" } }.first)
        }
        // A logged-in main window always has the tab buttons, so no tabs means the login screen,
        // unless a detached chat is still open, which means only the main window was closed.
        if sawChat && !sawTabs { throw Failure("no_window") }
        throw Failure(sawTabs ? "not_on_chats_tab" : "logged_out")
    }

    /// A chat's detached window, which works independently of whatever the main window shows.
    static func detached(_ name: String) throws -> UI {
        guard let app = wechatApp() else { throw Failure("wechat_not_running") }
        // The "(Window)" suffix matters: an image viewer window is titled with the bare chat name.
        let found = wechatWindows().filter { !isMainWindow($0) && isDetachedTitle(str($0, kAXTitleAttribute) ?? "", of: name) }
        if found.count > 1 { throw Failure("detached_ambiguous") }
        guard let w = found.first, let table = firstTable(w) else { throw Failure("no_detached_window") }
        return UI(pid: app.processIdentifier, window: w, chatList: table, messages: table, header: nil, input: firstInput(w))
    }

    private static func isChatList(_ table: AXUIElement) -> Bool {
        list(table, kAXRowsAttribute).prefix(5).contains { innerCell($0).flatMap { str($0, kAXIdentifierAttribute) }?.hasPrefix("MMChatsTableCellView") == true }
    }

    private static func innerCell(_ row: AXUIElement) -> AXUIElement? {
        children(row).first.flatMap { children($0).first }
    }

    func rows() -> [ChatRow] {
        list(chatList, kAXRowsAttribute).enumerated().compactMap { i, r in
            UI.innerCell(r).flatMap { str($0, kAXTitleAttribute) }.map { ChatRow(row: r, title: $0, position: i) }
        }
    }

    /// Exactly one row may match. Missing and ambiguous names are both rejected.
    func resolve(_ name: String, in rows: [ChatRow]) throws -> ChatRow {
        let found = rows.filter { rowMatches($0.title, name: name) }
        if found.isEmpty { throw Failure("chat_not_found") }
        if found.count > 1 { throw Failure("chat_ambiguous") }
        return found[0]
    }

    /// Tries the remembered position first, and a wrong position costs only a full scan,
    /// because the name is always checked. Duplicates are refused either way.
    func findRow(_ name: String) throws -> ChatRow {
        if let hint = try? sharedStore?.rowHint(name) {
            if hint.count > 1 { throw Failure("chat_ambiguous") }
            let all = list(chatList, kAXRowsAttribute)
            if hint.position < all.count, let title = UI.innerCell(all[hint.position]).flatMap({ str($0, kAXTitleAttribute) }),
               rowMatches(title, name: name) {
                return ChatRow(row: all[hint.position], title: title, position: hint.position)
            }
        }
        let scanned = rows()
        let row = try resolve(name, in: scanned)
        let count = scanned.filter { rowName($0.title) == rowName(row.title) }.count
        try? sharedStore?.rememberRow(rowName(row.title), position: row.position, count: count)
        return row
    }

    /// Opens a chat that isn't in the chat list, through the search box. The box is always cleared first,
    /// its focus is checked before typing, and only one exact name in the results is accepted.
    func openViaSearch(_ name: String) throws {
        guard let field = searchField else { throw Failure("chat_not_found") }
        let source = CGEventSource(stateID: .hidSystemState)
        let front = NSWorkspace.shared.frontmostApplication
        defer { front?.activate(options: []) }
        func key(_ code: CGKeyCode, command: Bool = false) {
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
                if command { e?.flags = .maskCommand }
                e?.postToPid(pid)
            }
        }
        func text() -> String? { children(field).first { role($0) == "AXTextField" }.flatMap { str($0, kAXValueAttribute) } }

        wechatApp()?.activate(options: [])
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        Thread.sleep(forTimeInterval: 0.2)
        guard let at = center(field) else { throw Failure("chat_not_found") }
        click(at, source)
        let app = AXUIElementCreateApplication(pid)
        var focused = false
        for _ in 0..<100 where !focused {
            Thread.sleep(forTimeInterval: 0.01)
            if let f = attr(app, kAXFocusedUIElementAttribute), children(field).contains(where: { CFEqual($0, f) }) { focused = true }
        }
        guard focused else { throw Failure("search_not_focused") }
        key(0, command: true)
        key(51)
        for _ in 0..<50 where text()?.isEmpty == false { Thread.sleep(forTimeInterval: 0.01) }
        guard text()?.isEmpty != false else { throw Failure("search_not_cleared") }

        let chars = Array(name.utf16)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
            chars.withUnsafeBufferPointer { e?.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: $0.baseAddress) }
            e?.postToPid(pid)
        }
        var hits: [AXUIElement] = []
        for _ in 0..<300 where hits.isEmpty {
            Thread.sleep(forTimeInterval: 0.01)
            guard text() == name else { continue }
            for w in wechatWindows() where str(w, kAXSubroleAttribute) == "AXUnknown" {
                guard let table = firstTable(w) else { continue }
                hits = list(table, kAXRowsAttribute).filter { r in
                    let parts = children(r).first.map(children) ?? []
                    return parts.contains { role($0) == "AXImage" } && parts.contains { role($0) == "AXStaticText" && str($0, kAXValueAttribute) == name }
                }
            }
        }
        guard hits.count == 1, let at = center(hits[0]) else {
            key(53)
            throw Failure(hits.isEmpty ? "chat_not_found" : "chat_ambiguous")
        }
        click(at, source)
    }

    private var searchField: AXUIElement? {
        guard let split = children(window).first(where: { role($0) == "AXSplitGroup" }) else { return nil }
        return children(split).first { str($0, kAXSubroleAttribute) == "AXSearchField" }
    }

    private func center(_ e: AXUIElement) -> CGPoint? {
        guard let p = attr(e, kAXPositionAttribute), let s = attr(e, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &origin)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        return CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
    }

    private func click(_ at: CGPoint, _ source: CGEventSource?) {
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: at, mouseButton: .left)?.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    /// The name shown by both the input box and the header, or nil if they disagree.
    /// A detached window has no separate header, because it only ever shows one chat.
    var activeChat: String? {
        guard let title = input.flatMap({ str($0, kAXTitleAttribute) }), !title.isEmpty else { return nil }
        guard let header else { return title }
        guard let head = str(header, kAXValueAttribute), head == title || head.hasPrefix(title + " (") else { return nil }
        return title
    }

    var inputValue: String? { input.flatMap { str($0, kAXValueAttribute) } }

    /// `tail` limits reading to the newest rows, since backfill can leave thousands loaded.
    func cells(tail: Int? = nil) -> [Cell] {
        guard let messages else { return [] }
        let rows = list(messages, kAXRowsAttribute)
        let first = tail.map { max(0, rows.count - $0) } ?? 0
        return (first..<rows.count).compactMap { i in
            guard let c = UI.innerCell(rows[i]), let id = str(c, kAXIdentifierAttribute) else { return nil }
            // Detached windows name their cells differently. One name keeps history keys the same in both.
            return Cell(kind: id.replacingOccurrences(of: "InNewSingleWindow", with: ""), title: str(c, kAXTitleAttribute) ?? "", row: i)
        }
    }

    var atBottom: Bool {
        guard let messages, let last = list(messages, kAXRowsAttribute).last else { return false }
        return list(messages, kAXVisibleRowsAttribute).contains { CFEqual($0, last) }
    }

    private var scrollBar: AXUIElement? {
        messages.flatMap { attr($0, kAXParentAttribute) }.map { $0 as! AXUIElement }
            .flatMap { children($0).first { role($0) == "AXScrollBar" } }
    }

    func scroll(to value: Double) {
        guard let scrollBar else { return }
        AXUIElementSetAttributeValue(scrollBar, kAXValueAttribute as CFString, value as CFNumber)
    }

    /// Saves an image by opening WeChat's viewer and copying it. No screenshots, and the clipboard is put back.
    /// Returns nil if the image can't be copied, for example when it was never downloaded.
    func saveImage(_ m: Message, title: String) -> String? {
        guard let messages else { return nil }
        let rows = list(messages, kAXRowsAttribute)
        guard m.row < rows.count, let outer = children(rows[m.row]).first, let cell = UI.innerCell(rows[m.row]),
              str(cell, kAXIdentifierAttribute)?.hasPrefix("MMImageMessageCellView") == true, str(cell, kAXTitleAttribute) == title else { return nil }
        AXUIElementSetAttributeValue(outer, "AXScrollToVisible" as CFString, kCFBooleanTrue)
        Thread.sleep(forTimeInterval: 0.3)

        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item in item.types.compactMap { t in item.data(forType: t).map { (t, $0) } } }
        let before = board.changeCount
        let ax = AXUIElementCreateApplication(pid)
        let known = list(ax, kAXWindowsAttribute)
        guard AXUIElementPerformAction(cell, kAXPressAction as CFString) == .success else { return nil }
        var viewer: AXUIElement?
        for _ in 0..<15 where viewer == nil {
            Thread.sleep(forTimeInterval: 0.2)
            viewer = list(ax, kAXWindowsAttribute).first { w in !known.contains { CFEqual($0, w) } }
        }
        guard let viewer else { return nil }
        defer {
            if let close = attr(viewer, kAXCloseButtonAttribute) {
                AXUIElementPerformAction(close as! AXUIElement, kAXPressAction as CFString)
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        AXUIElementPerformAction(viewer, kAXRaiseAction as CFString)
        Thread.sleep(forTimeInterval: 1.0)  // the viewer needs a moment to load the full image

        var png: Data?
        for _ in 0..<3 where png == nil {
            pressCopy()
            for _ in 0..<10 where board.changeCount == before {
                Thread.sleep(forTimeInterval: 0.1)
            }
            if board.changeCount != before {
                png = board.data(forType: .png)
                    ?? board.data(forType: .tiff).flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
            }
        }
        let copied = board.changeCount
        var path: String?
        if let png {
            let folder = dataDir.appendingPathComponent("images")
            let url = folder.appendingPathComponent(UUID().uuidString + "." + imageExtension(png))
            if (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])) != nil,
               FileManager.default.createFile(atPath: url.path, contents: png, attributes: [.posixPermissions: 0o600]) {
                path = url.path
            }
        }
        // A newer copy by the user wins, so the old clipboard only returns if nothing changed since ours.
        if copied != before && board.changeCount == copied {
            board.clearContents()
            board.writeObjects(saved.map { types in
                let item = NSPasteboardItem()
                for (t, d) in types { item.setData(d, forType: t) }
                return item
            })
        }
        return path
    }

    private func pressCopy() {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: down)
            e?.flags = .maskCommand
            e?.postToPid(pid)
        }
    }

    func setInput(_ text: String) -> Bool {
        guard let input else { return false }
        return AXUIElementSetAttributeValue(input, kAXValueAttribute as CFString, text as CFString) == .success
            && (inputValue ?? "") == text
    }

    /// Return goes to WeChat's key window, which may be a detached chat. Sending is only safe once
    /// WeChat itself reports this input as focused.
    func focusInput() -> Bool {
        guard let input else { return false }
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(input, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        let app = AXUIElementCreateApplication(pid)
        for _ in 0..<10 {
            Thread.sleep(forTimeInterval: 0.1)
            if let focused = attr(app, kAXFocusedUIElementAttribute), CFEqual(focused, input) { return true }
        }
        return false
    }

    func pressReturn() {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: down)?.postToPid(pid)
        }
    }
}

/// Double-clicks a chat row, which is how WeChat opens a detached window. Needs a real click, so the cursor moves.
func detachChat(_ name: String) throws {
    if (try? UI.detached(name)) != nil { return }
    var ui = try UI.locate()
    var found: ChatRow?
    do {
        found = try ui.findRow(name)
    } catch let f as Failure where f.reason == "chat_not_found" {
        ui = try openChat(name).ui  // search adds it to the chat list
        found = try ui.findRow(name)
    }
    guard let row = found else { throw Failure("detach_failed") }
    try withFocusLock { try doubleClick(row, ui: ui, name: name) }
}

private func doubleClick(_ row: ChatRow, ui: UI, name: String) throws {
    let front = NSWorkspace.shared.frontmostApplication
    wechatApp()?.activate(options: [])
    AXUIElementPerformAction(ui.window, kAXRaiseAction as CFString)
    Thread.sleep(forTimeInterval: 0.6)
    guard let outer = children(row.row).first, let cell = children(outer).first else { throw Failure("detach_failed") }
    AXUIElementSetAttributeValue(outer, "AXScrollToVisible" as CFString, kCFBooleanTrue)
    Thread.sleep(forTimeInterval: 0.5)
    guard let p = attr(cell, kAXPositionAttribute), let s = attr(cell, kAXSizeAttribute) else { throw Failure("detach_failed") }
    var origin = CGPoint.zero, size = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &origin)
    AXValueGetValue(s as! AXValue, .cgSize, &size)
    let at = CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
    let source = CGEventSource(stateID: .hidSystemState)
    for click in 1...2 {
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: at, mouseButton: .left)
            e?.setIntegerValueField(.mouseEventClickState, value: Int64(click))
            e?.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.04)
        }
    }
    defer { front?.activate(options: []) }
    for _ in 0..<25 {
        Thread.sleep(forTimeInterval: 0.2)
        if (try? UI.detached(name)) != nil { return }
    }
    throw Failure("detach_failed")
}

/// Opens the chat and returns a fresh UI plus its messages, never another chat's.
func openChat(_ name: String, tail: Int? = nil) throws -> (ui: UI, cells: [Cell]) {
    let ui = try UI.locate()
    // Debug switch: exercises the search path with a chat that is in the list.
    let forceSearch = ProcessInfo.processInfo.environment["WECHAT_ADAPTER_FORCE_SEARCH"] != nil
    var row: ChatRow?
    do {
        if !forceSearch { row = try ui.findRow(name) }
    } catch let f as Failure where f.reason == "chat_not_found" {
        log("not in chat list, trying search")
    }
    if ui.activeChat == name {
        let cells = ui.cells(tail: tail)
        if cells.isEmpty { throw Failure("chat_unreadable") }
        return (ui, cells)
    }
    let previous = ui.cells(tail: tail)
    if let row {
        let rc = AXUIElementSetAttributeValue(row.row, kAXSelectedAttribute as CFString, kCFBooleanTrue)
        guard rc == .success else { throw Failure("chat_switch_failed") }
    } else {
        try withFocusLock { try ui.openViaSearch(name) }
    }
    // The input title can update before the table reloads, so wait for changed, stable messages.
    for _ in 0..<20 {
        Thread.sleep(forTimeInterval: 0.2)
        let fresh = try UI.locate()
        guard fresh.activeChat == name else { continue }
        let first = fresh.cells(tail: tail)
        Thread.sleep(forTimeInterval: 0.2)
        let second = fresh.cells(tail: tail)
        if !first.isEmpty, first == second, first != previous, fresh.activeChat == name {
            return (fresh, second)
        }
    }
    throw Failure("chat_switch_unverified")
}
