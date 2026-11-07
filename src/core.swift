// Pure logic with no UI or disk access, covered by `wechat-adapter selftest`.
import CryptoKit
import Foundation

struct Cell: Equatable {
    let kind: String   // AXIdentifier of the message cell
    let title: String
    var row = 0        // table row, used to open an image
}

struct Message {
    let key: String    // hash of the cell, used only to align snapshots
    let sender: String?
    let isSelf: Bool?
    let type: String
    let text: String?
    let displayedTime: String?
    let sentMinute: String?
    let row: Int
}

func sha(_ s: String) -> String {
    SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
}

/// Labels are English-UI only: own text is "MeSaid:<text>", own media is "Me:<label>".
/// shortcut: a peer whose display name is "Me" reads as self, upgrade if a cell attribute proves authorship.
func parseSender(_ title: String, isText: Bool) -> (sender: String?, isSelf: Bool?, body: String) {
    if isText {
        guard let r = title.range(of: "Said:") else { return (nil, nil, title) }
        let name = String(title[..<r.lowerBound])
        return (name.isEmpty ? nil : name, name.isEmpty ? nil : name == "Me", String(title[r.upperBound...]))
    }
    guard let r = title.range(of: ":") else { return (nil, nil, title) }
    let name = String(title[..<r.lowerBound])
    return (name.isEmpty ? nil : name, name.isEmpty ? nil : name == "Me", String(title[r.upperBound...]))
}

/// Every message is text or an image. Links and replies are stored as text. Stickers and unknown cells are skipped.
func parseMessages(_ cells: [Cell], now: Date = Date()) -> [Message] {
    var time: String?
    var out: [Message] = []
    for c in cells {
        if c.kind == "MMTimeStampCellView" { time = c.title; continue }
        let isSaid = c.kind == "MMTextMessageCellView" || c.kind == "MMAppReferMessageCellView"
        guard isSaid || c.kind == "MMAppUrlMessageCellView" || c.kind == "MMImageMessageCellView" else { continue }
        let isImage = c.kind == "MMImageMessageCellView"
        let p = parseSender(c.title, isText: isSaid)
        out.append(Message(key: sha(c.kind + "\0" + c.title), sender: p.sender, isSelf: p.isSelf, type: isImage ? "image" : "text",
                           text: isImage ? nil : p.body, displayedTime: time, sentMinute: sentMinute(time, now: now), row: c.row))
    }
    return out
}

/// Index in `new` where unseen messages start, or nil if the snapshots do not overlap.
/// A match must be all of `old`, or reach the start of `new` (older rows scrolled out).
/// This keeps identical messages distinct: their position counts, not just their text.
func unseenStart(old: [String], new: [String]) -> Int? {
    if old.isEmpty { return 0 }
    for k in stride(from: min(old.count, new.count), to: 0, by: -1) {
        let tail = Array(old.suffix(k))
        let starts = k == old.count ? Array(0...(new.count - k)) : [0]
        for p in starts where Array(new[p..<(p + k)]) == tail { return p + k }
    }
    return nil
}

/// Turns WeChat's time label into local "yyyy-MM-dd HH:mm", or nil for a label it can't place.
/// A label covers the messages after it, so the result is approximate.
func sentMinute(_ label: String?, now: Date) -> String? {
    guard let parts = label?.split(separator: " ").map(String.init), let clock = parts.last,
          clock.range(of: #"^\d{1,2}:\d{2}$"#, options: .regularExpression) != nil else { return nil }
    let hm = clock.split(separator: ":").compactMap { Int($0) }
    let cal = Calendar.current
    var day = cal.dateComponents([.year, .month, .day], from: now)
    if parts.count == 2 {
        let word = parts[0]
        let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        var back: Int?
        if word == "Yesterday" { back = 1 }
        if let i = weekdays.firstIndex(of: word) {
            let delta = (cal.component(.weekday, from: now) - (i + 1) + 7) % 7
            back = delta == 0 ? 7 : delta
        }
        if let back, let d = cal.date(byAdding: .day, value: -back, to: now) {
            day = cal.dateComponents([.year, .month, .day], from: d)
        } else {
            let ymd = word.split(separator: "/").compactMap { Int($0) }
            guard ymd.count == 3 else { return nil }
            day = DateComponents(year: ymd[0], month: ymd[1], day: ymd[2])
        }
    } else if parts.count == 4 {
        // "Aug 12, 2026 03:51"
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        guard let m = months.firstIndex(of: parts[0]), let d = Int(parts[1].dropLast()), let y = Int(parts[2]) else { return nil }
        day = DateComponents(year: y, month: m + 1, day: d)
    } else if parts.count != 1 {
        return nil
    }
    guard let y = day.year, let m = day.month, let d = day.day else { return nil }
    return String(format: "%04d-%02d-%02d %02d:%02d", y, m, d, hm[0], hm[1])
}

/// Aligns a window of messages with saved history: window[i] is existing[i + offset].
/// The largest clean overlap wins, and on a tie the newest position, or nil if nothing lines up.
func historyOffset(existing: [String], window: [String]) -> Int? {
    var best: Int?
    var bestOverlap = 0
    for o in stride(from: existing.count - 1, through: -(window.count - 1), by: -1) {
        let lo = max(0, -o), hi = min(window.count, existing.count - o)
        guard hi - lo > bestOverlap else { continue }
        if (lo..<hi).allSatisfy({ window[$0] == existing[$0 + o] }) {
            best = o
            bestOverlap = hi - lo
        }
    }
    return best
}

/// The row label is "name,preview,time,…". A preview follows the comma directly, while generated group
/// names use ", ", so "Ann, Bob,hi" is not a row for "Ann". A false miss just gives chat_not_found.
func rowMatches(_ title: String, name: String) -> Bool {
    title == name || (title.hasPrefix(name + ",") && !title.hasPrefix(name + ", "))
}

/// Best-effort name for display and watch keys: ends at the first comma not followed by a space,
/// since previews follow directly while generated group names use ", ".
func rowName(_ title: String) -> String {
    let chars = Array(title)
    for i in chars.indices where chars[i] == "," && (i + 1 == chars.count || chars[i + 1] != " ") {
        return String(chars[..<i])
    }
    return title
}

/// Row identity for change detection: name, preview and time only. WeChat's unread text is unreliable
/// (seen attached to about 374 rows at once, then removed), so it must never count as activity.
func rowFingerprint(_ title: String) -> String {
    var s = title.replacingOccurrences(of: #"\d+ unread message\(s\),?"#, with: "", options: .regularExpression)
    s = s.replacingOccurrences(of: #"\[\d+ [A-Za-z]+\] ?"#, with: "", options: .regularExpression)
    return sha(s.hasSuffix(",") ? String(s.dropLast()) : s)
}

/// WeChat's clipboard "png" often holds the original JPEG or GIF bytes, so the name follows the content.
func imageExtension(_ data: Data) -> String {
    if data.starts(with: [0xFF, 0xD8]) { return "jpg" }
    if data.starts(with: [0x47, 0x49, 0x46]) { return "gif" }
    return "png"
}

/// The newest messages of `older`, stopping before `maxImages` is exceeded, so one UI turn stays short.
func newestBatch(_ older: [Message], maxImages: Int) -> [Message] {
    var images = 0
    var start = older.count
    while start > 0 {
        if older[start - 1].type == "image" {
            if images == maxImages { break }
            images += 1
        }
        start -= 1
    }
    return Array(older[start...])
}

/// WeChat titles a detached window "<chat>(Window)", and a group's "<chat>(<members>)(Window)".
func detachedChatName(_ title: String) -> String {
    guard title.hasSuffix("(Window)") else { return title }
    let name = String(title.dropLast("(Window)".count))
    return name.replacingOccurrences(of: #"\(\d+\)$"#, with: "", options: .regularExpression)
}

/// Whether a window title belongs to this chat. A chat whose own name ends in "(3)" must still match.
func isDetachedTitle(_ title: String, of name: String) -> Bool {
    title == name + "(Window)" || (title.hasSuffix("(Window)") && detachedChatName(title) == name)
}

func selftest() {
    let t = parseSender("MeSaid:a:b", isText: true)
    precondition(t.sender == "Me" && t.isSelf == true && t.body == "a:b")
    let peer = parseSender("BobSaid:hi", isText: true)
    precondition(peer.sender == "Bob" && peer.isSelf == false && peer.body == "hi")
    let unknown = parseSender("no label here", isText: true)
    precondition(unknown.sender == nil && unknown.isSelf == nil && unknown.body == "no label here")
    precondition(parseSender("Me:Sent a Photo", isText: false).isSelf == true)

    let ms = parseMessages([Cell(kind: "MMTimeStampCellView", title: "12:00"),
                            Cell(kind: "MMTextMessageCellView", title: "MeSaid:x"),
                            Cell(kind: "MMImageMessageCellView", title: "Me:Sent a Photo"),
                            Cell(kind: "MMNewThingCellView", title: "?")])
    precondition(ms.count == 2 && ms[0].displayedTime == "12:00" && ms[0].text == "x")
    precondition(ms[1].type == "image" && ms[1].text == nil)
    // A reply label holds the reply and the quote, and commas make them inseparable, so text keeps both.
    let reply = parseMessages([Cell(kind: "MMAppReferMessageCellView", title: "MeSaid:ok,Bob,Bob: hi")])[0]
    precondition(reply.type == "text" && reply.isSelf == true && reply.sender == "Me" && reply.text == "ok,Bob,Bob: hi")
    precondition(parseMessages([Cell(kind: "MMStickerMessageCellView", title: "Bob:Sent Sticker")]).isEmpty)
    let link = parseMessages([Cell(kind: "MMAppUrlMessageCellView", title: "Me:Link Title,desc")])[0]
    precondition(link.type == "text" && link.isSelf == true && link.text == "Link Title,desc")

    precondition(imageExtension(Data([0xFF, 0xD8, 0xFF])) == "jpg" && imageExtension(Data([0x89, 0x50])) == "png")

    let batch = parseMessages([Cell(kind: "MMImageMessageCellView", title: "Me:a"), Cell(kind: "MMTextMessageCellView", title: "MeSaid:b"),
                               Cell(kind: "MMImageMessageCellView", title: "Me:c"), Cell(kind: "MMTextMessageCellView", title: "MeSaid:d")])
    precondition(newestBatch(batch, maxImages: 1).count == 3 && newestBatch(batch, maxImages: 2).count == 4)

    precondition(detachedChatName("File Transfer(Window)") == "File Transfer" && detachedChatName("Bob") == "Bob")
    precondition(detachedChatName("Team(8)(Window)") == "Team" && isDetachedTitle("Team(8)(Window)", of: "Team"))
    precondition(isDetachedTitle("Odd(3)(Window)", of: "Odd(3)") && !isDetachedTitle("Team", of: "Team"))

    let friday = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 12))!
    precondition(sentMinute("19:20", now: friday) == "2026-11-06 19:20")
    precondition(sentMinute("Yesterday 09:05", now: friday) == "2026-11-05 09:05")
    precondition(sentMinute("Monday 09:05", now: friday) == "2026-11-02 09:05")
    precondition(sentMinute("Friday 09:05", now: friday) == "2026-10-30 09:05")
    precondition(sentMinute("2025/1/2 09:05", now: friday) == "2025-01-02 09:05")
    precondition(sentMinute("Aug 12, 2026 03:51", now: friday) == "2026-08-12 03:51")
    precondition(sentMinute("Sep 1, 2026 06:11", now: friday) == "2026-09-01 06:11")
    precondition(sentMinute("Some Odd Label", now: friday) == nil && sentMinute(nil, now: friday) == nil)

    precondition(historyOffset(existing: ["c", "d"], window: ["a", "b", "c"]) == -2)      // older loaded
    precondition(historyOffset(existing: ["a", "b"], window: ["b", "c"]) == 1)            // newer arrived
    precondition(historyOffset(existing: ["a", "b", "c"], window: ["b"]) == 1)            // already saved
    precondition(historyOffset(existing: ["x", "x"], window: ["x", "x", "x"]) == 0)       // identical stay distinct
    precondition(historyOffset(existing: ["a"], window: ["b"]) == nil)

    precondition(unseenStart(old: [], new: ["a"]) == 0)
    precondition(unseenStart(old: ["a", "b"], new: ["a", "b"]) == 2)
    precondition(unseenStart(old: ["a", "b"], new: ["a", "b", "c"]) == 2)
    precondition(unseenStart(old: ["x", "x"], new: ["x", "x", "x"]) == 2)            // identical message stays distinct
    precondition(unseenStart(old: ["a", "b"], new: ["a", "b", "z", "a", "b"]) == 2)  // repeat is not an overlap
    precondition(unseenStart(old: ["a", "b", "c"], new: ["c", "d"]) == 1)            // older rows dropped out
    precondition(unseenStart(old: ["q", "a", "b"], new: ["p", "q", "a", "b"]) == 4)  // older rows loaded in
    precondition(unseenStart(old: ["a", "b", "c"], new: ["a", "c", "d"]) == nil)     // middle changed: report a gap
    precondition(unseenStart(old: ["a"], new: ["b"]) == nil)
    precondition(unseenStart(old: ["a"], new: []) == nil)

    precondition(rowMatches("Bob,hi,12:00", name: "Bob") && rowMatches("Bob", name: "Bob"))
    precondition(!rowMatches("Bobby,hi", name: "Bob"))
    precondition(!rowMatches("Ann, Bob,hi,12:00", name: "Ann"))
    precondition(rowMatches("Ann, Bob,hi,12:00", name: "Ann, Bob"))
    let plain = rowFingerprint("Bob,hi,12:00")
    precondition(plain == rowFingerprint("Bob,hi,12:00,1 unread message(s)"))
    precondition(plain == rowFingerprint("Bob,[3 messages] hi,12:00"))
    precondition(rowFingerprint("Bob,hi,12:00,Muted") == rowFingerprint("Bob,hi,12:00,2 unread message(s),Muted"))
    precondition(plain != rowFingerprint("Bob,bye,12:00"))
    precondition(rowName("Bob,hi,12:00") == "Bob" && rowName("Ann, Bob,hi") == "Ann, Bob" && rowName("Bob") == "Bob")
}
