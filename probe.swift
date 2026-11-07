// Read-only capability probe: prints the shape of WeChat's accessibility tree.
// Text is replaced by its length so message content never reaches the output.
// Build: swiftc -O probe.swift -o probe
import AppKit
import ApplicationServices

let bundleID = "com.tencent.xinWeChat"
let maxDepth = 25
let maxNodes = 5000

func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
}

// --mask keeps punctuation and character classes only, to reveal label formats without content.
let mask = CommandLine.arguments.contains("--mask")
func masked(_ s: String) -> String {
    String(s.prefix(48).map { c -> Character in
        if c.isLetter { return c.isASCII ? "a" : "中" }
        return c.isNumber ? "9" : c
    })
}

func textShape(_ e: AXUIElement, _ name: String, _ tag: String) -> String? {
    guard let s = attr(e, name) as? String, !s.isEmpty else { return nil }
    return mask ? "\(tag)#\(s.count)=[\(masked(s).replacingOccurrences(of: "\n", with: "\\n"))]" : "\(tag)#\(s.count)"
}

func settable(_ e: AXUIElement, _ name: String) -> Bool {
    var b = DarwinBoolean(false)
    return AXUIElementIsAttributeSettable(e, name as CFString, &b) == .success && b.boolValue
}

var nodes = 0
var roleCounts: [String: Int] = [:]

func walk(_ e: AXUIElement, _ depth: Int) {
    guard nodes < maxNodes, depth <= maxDepth else { return }
    nodes += 1
    let role = attr(e, kAXRoleAttribute) as? String ?? "?"
    roleCounts[role, default: 0] += 1
    let kids = attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? []
    var names: CFArray?
    AXUIElementCopyActionNames(e, &names)
    let actions = (names as? [String] ?? []).filter { $0 != "AXShowMenu" && $0 != "AXScrollToVisible" }

    var parts = [role]
    if let s = attr(e, kAXSubroleAttribute) as? String { parts.append("sub=\(s)") }
    if let s = attr(e, kAXIdentifierAttribute) as? String, !s.isEmpty { parts.append("id=\(s)") }
    parts += [textShape(e, kAXTitleAttribute, "title"), textShape(e, kAXValueAttribute, "value"),
              textShape(e, kAXDescriptionAttribute, "desc"), textShape(e, kAXHelpAttribute, "help")].compactMap { $0 }
    if settable(e, kAXValueAttribute) { parts.append("value-settable") }
    if !actions.isEmpty { parts.append("actions=\(actions.joined(separator: ","))") }
    if !kids.isEmpty { parts.append("kids=\(kids.count)") }
    print(String(repeating: " ", count: depth) + parts.joined(separator: " "))
    kids.forEach { walk($0, depth + 1) }
}

let trusted = AXIsProcessTrusted()
print("ax_trusted=\(trusted)")
guard trusted else {
    print("Grant Accessibility to this terminal in System Settings > Privacy & Security > Accessibility.")
    exit(2)
}
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
    print("wechat_running=false")
    exit(3)
}
let ax = AXUIElementCreateApplication(app.processIdentifier)
AXUIElementSetMessagingTimeout(ax, 3)
let windows = attr(ax, kAXWindowsAttribute) as? [AXUIElement] ?? []
print("wechat_running=true pid=\(app.processIdentifier) hidden=\(app.isHidden) active=\(app.isActive) windows=\(windows.count)")
windows.forEach { walk($0, 0) }
print("nodes=\(nodes) truncated=\(nodes >= maxNodes) roles=\(roleCounts.sorted { $0.value > $1.value })")
