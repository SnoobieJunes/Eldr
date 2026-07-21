// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// One pending phone-side decision on a paired Mac coding-agent's mutating tool call
/// (ACPRouterplan Phase 3, statusreport §2.3). The node asks the phone for permission
/// (`session/request_permission`) before `write_file`/`edit_file`/`run_shell`; when the
/// owner has NOT pre-granted blanket autonomous-changes consent, the phone surfaces this
/// to the human and waits for an explicit choice.
public struct PermissionRequest: Sendable {
    /// Unique per request (the coordinator's queue key) — the node's permission RPC does
    /// not carry a stable tool-call id to the phone handler, so the runtime mints one.
    public let id: String
    /// The node's PQRC identity hex (which paired Mac is asking). Lets a teardown cancel
    /// exactly that node's pending prompts.
    public let nodeHex: String
    /// Human-readable action, already including the resolved command/path
    /// (`ToolExecutor.title(for:args:)`) — e.g. "Run: xcodebuild …" or "Write Foo.swift".
    /// NOTE: never the file CONTENTS — only the action descriptor crosses to the phone.
    public let title: String
    /// The ACP ToolKind ("edit" | "execute" | "other") — drives the icon/wording.
    public let kind: String

    public init(id: String, nodeHex: String, title: String, kind: String) {
        self.id = id
        self.nodeHex = nodeHex
        self.title = title
        self.kind = kind
    }
}

/// The human's choice. `allowAlways` additionally flips the per-node autonomous-changes
/// consent so future turns stop prompting; `deny` fails the tool closed.
public enum ACPPermissionDecision: Sendable {
    case allowOnce
    case allowAlways
    case deny
}

/// The seam the (actor) `PersonaRuntime` calls to ask the human and to cancel pending
/// prompts on teardown. `Sendable` so the actor can hold it; the concrete
/// `ACPPermissionCoordinator` is `@MainActor` (the UI owns the queue), and its methods
/// satisfy these async requirements across the actor hop.
public protocol ACPPermissionAsking: Sendable {
    func request(_ req: PermissionRequest) async -> ACPPermissionDecision
    /// Resume every still-pending request for `nodeHex` with `.deny` — called when that
    /// node's relay-ACP transport tears down (consent revoked / silo lock) so no `await`
    /// is orphaned and nothing is left auto-allowable.
    func cancelAll(nodeHex: String) async
}

/// Owns the queue of pending per-tool permission prompts and bridges the runtime's
/// `async` permission handler to a SwiftUI alert. `@MainActor @Observable` so a view can
/// drive an `.alert` off `pending.first` and the buttons resolve the awaiting handler.
///
/// **Fail-closed by design.** The node's own C-1 gate (`ACPAgent.requestPermission`,
/// default 120s → deny) is the real brake: if the human never answers, the NODE denies
/// the tool on its own and the file/shell op never runs. This coordinator is the UX
/// affordance + a hygiene layer — `cancelAll` resolves orphaned awaits with `.deny` so a
/// teardown can never strand a continuation or leave a prompt secretly "open".
@MainActor
@Observable
public final class ACPPermissionCoordinator: ACPPermissionAsking {

    /// Mirror of the node's C-1 auto-deny window (`ACPAgent.requestPermission`,
    /// default 120 s). When it lapses the phone resolves `.deny` itself and
    /// reports it via `onExpired`, so the queue can't hold a prompt the node has
    /// already given up on (C4 — the "silent expiry" fix).
    public static let expirySeconds: TimeInterval = 120

    /// A queued prompt awaiting the human. FIFO; the UI presents `pending.first`.
    public struct Pending: Identifiable {
        public let id: String
        public let nodeHex: String
        public let title: String
        public let kind: String
        /// The handler suspended on this; resolving the prompt resumes it.
        let continuation: CheckedContinuation<ACPPermissionDecision, Never>
    }

    public private(set) var pending: [Pending] = []

    /// C4 hooks, wired by `AppModel`: a new prompt arrived (haptic + optional
    /// local notification) / a prompt sat unanswered past the C-1 window and was
    /// denied (render the "expired" system row in that node's chat).
    public var onNewRequest: ((_ nodeHex: String, _ title: String, _ kind: String) -> Void)?
    public var onExpired: ((_ nodeHex: String, _ title: String) -> Void)?

    public init() {}

    /// Park until the human resolves this request. Appends to the (observed) queue so a
    /// SwiftUI alert appears; resumes when `resolve` (or `cancelAll`) is called.
    public func request(_ req: PermissionRequest) async -> ACPPermissionDecision {
        onNewRequest?(req.nodeHex, req.title, req.kind)
        // C4: mirror the node's C-1 timeout phone-side. If the human never
        // answers, resolve .deny (matching what the node already did) and let
        // the app render an explicit "expired" row instead of a silent vanish.
        let id = req.id
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.expirySeconds))
            self?.expire(id: id)
        }
        return await withCheckedContinuation { continuation in
            pending.append(
                Pending(
                    id: req.id, nodeHex: req.nodeHex, title: req.title, kind: req.kind,
                    continuation: continuation))
        }
    }

    /// Resolve a prompt from the UI. No-op if already resolved/cancelled (idempotent).
    public func resolve(id: String, _ decision: ACPPermissionDecision) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        let entry = pending.remove(at: index)
        entry.continuation.resume(returning: decision)
    }

    /// C4: the C-1 window lapsed with no answer — deny (idempotent with resolve)
    /// and surface it. Private: only the timer scheduled in `request` calls this.
    private func expire(id: String) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        let entry = pending.remove(at: index)
        entry.continuation.resume(returning: .deny)
        onExpired?(entry.nodeHex, entry.title)
    }

    /// Deny + drop every pending prompt for a node (its transport tore down). Never
    /// leaves a continuation parked.
    public func cancelAll(nodeHex: String) {
        let doomed = pending.filter { $0.nodeHex == nodeHex }
        pending.removeAll { $0.nodeHex == nodeHex }
        for entry in doomed { entry.continuation.resume(returning: .deny) }
    }
}
