import ApplicationServices
import CoreGraphics
import Foundation

@testable import NanoTeams

/// An in-memory stand-in for one node of a process's Accessibility tree.
///
/// A real AX tree belongs to ANOTHER process and cannot be constructed, which is why
/// `AccessibilityInspector`'s traversal — a budget state machine with a depth cap, a node cap, a
/// wall-clock deadline, a cancellation poll and web-area propagation — had no test that could reach
/// it. This is the fixture the `AXNodeReading` seam exists to allow.
final class FakeAXNode: @unchecked Sendable {
    var strings: [String: String] = [:]
    var flags: [String: Bool] = [:]
    /// Named relations other than `children` — today only `kAXWindowsAttribute` (inspector).
    var related: [String: [FakeAXNode]] = [:]
    var frame: CGRect?
    var children: [FakeAXNode] = []

    init(
        role: String? = nil,
        title: String? = nil,
        value: String? = nil,
        desc: String? = nil,
        frame: CGRect? = nil,
        children: [FakeAXNode] = []
    ) {
        if let role { strings[kAXRoleAttribute as String] = role }
        if let title { strings[kAXTitleAttribute as String] = title }
        if let value { strings[kAXValueAttribute as String] = value }
        if let desc { strings[kAXDescriptionAttribute as String] = desc }
        self.frame = frame
        self.children = children
    }

    /// A button that maps cleanly into a 100×100-pixel capture of a 100×100-point region.
    static func button(_ title: String, x: Int, y: Int, w: Int = 10, h: Int = 10) -> FakeAXNode {
        FakeAXNode(
            role: "AXButton", title: title,
            frame: CGRect(x: x, y: y, width: w, height: h))
    }

    @discardableResult
    func adding(_ child: FakeAXNode) -> FakeAXNode {
        children.append(child)
        return self
    }
}

/// Records reads and writes so a test can assert what the walk ASKED for, not only what it
/// returned — which is how "the enable is idempotent" becomes checkable at all.
final class FakeAXReader: AXNodeReading, @unchecked Sendable {
    typealias Node = FakeAXNode

    /// Root returned by `applicationNode(pid:)`, per pid. A missing pid yields `fallbackRoot`.
    var rootsByPID: [pid_t: FakeAXNode] = [:]
    var fallbackRoot = FakeAXNode()

    private(set) var applicationNodeRequests: [pid_t] = []
    private(set) var setTrueCalls: [(attribute: String, node: ObjectIdentifier)] = []
    private(set) var messagingTimeouts: [Double] = []
    private(set) var childrenReads = 0
    private(set) var frameReads = 0
    private(set) var elementsReads: [String] = []

    /// Ran on every `children(of:)` call — lets a test burn the walk's wall-clock deadline, or flip
    /// the cancellation flag, at a deterministic point in the traversal.
    var onChildren: ((FakeAXNode) -> Void)?

    init(root: FakeAXNode? = nil) {
        if let root { fallbackRoot = root }
    }

    func applicationNode(pid: pid_t) -> FakeAXNode {
        applicationNodeRequests.append(pid)
        return rootsByPID[pid] ?? fallbackRoot
    }

    func string(_ attribute: String, of node: FakeAXNode) -> String? {
        node.strings[attribute]
    }

    func boolValue(_ attribute: String, of node: FakeAXNode) -> Bool? {
        node.flags[attribute]
    }

    func frame(of node: FakeAXNode) -> CGRect? {
        frameReads += 1
        return node.frame
    }

    func children(of node: FakeAXNode) -> [FakeAXNode] {
        childrenReads += 1
        onChildren?(node)
        return node.children
    }

    func elements(_ attribute: String, of node: FakeAXNode) -> [FakeAXNode] {
        elementsReads.append(attribute)
        return node.related[attribute] ?? []
    }

    func setTrue(_ attribute: String, on node: FakeAXNode) {
        setTrueCalls.append((attribute, ObjectIdentifier(node)))
        node.flags[attribute] = true
    }

    func setMessagingTimeout(_ seconds: Double, on node: FakeAXNode) {
        messagingTimeouts.append(seconds)
    }
}
