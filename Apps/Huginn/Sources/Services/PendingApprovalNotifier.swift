import Combine
import Foundation
import UserNotifications

/// Fires a local OS notification the moment a NEW tool-approval request appears in
/// either owner-approval surface Huginn has:
///  - the A2A gate (`InboundTaskGate`, mirrored into `A2AServerHost.pendingApprovals`),
///    which approves a whole inbound A2A TASK before it runs, and
///  - Test Chat's own `session/request_permission` gate
///    (`TestChatSession.pendingApprovals`), which approves one tool call.
///
/// Both gates deny-on-timeout after 120s (`InboundTaskGate.timeoutSeconds`,
/// `TestChatSession`'s own `scheduleApprovalTimeout`) — a request that never surfaces
/// to a human (Huginn backgrounded, menu bar all that's showing) silently gets eaten
/// by that timeout. This makes it visible even then.
///
/// Authorization is requested LAZILY, on the first pending approval this process ever
/// sees — never at launch, so a user who never enables A2A serving or opens Test Chat
/// is never prompted for notification permission.
///
/// PRIVACY (invariant 12): the notification carries NO arguments/payloads — only a
/// generic title and a content-free "what kind of thing" label. The A2A gate's
/// `PendingApproval.summary` is the actual task PROMPT (up to 200 chars) and must
/// never appear in a banner visible on the lock screen; Test Chat's `title` embeds
/// the tool's ARGUMENT (a file path / shell command / search query — see
/// `ToolExecutor.title(for:args:)`) and is reduced to just its leading verb before
/// use, for the same reason.
@MainActor
final class PendingApprovalNotifier: ObservableObject {
    private var authorizationRequested = false
    private var knownA2AIDs: Set<UUID> = []
    private var knownTestChatIDs: Set<UUID> = []
    private var cancellables: Set<AnyCancellable> = []

    /// Wire this notifier to both pending-approval surfaces. Call once, from the
    /// composition root (`HuginnApp`), once both hosts exist. Idempotent — re-calling
    /// just re-subscribes (harmless; the old subscriptions are dropped when
    /// `cancellables` is overwritten by the fresh `.store` insert... actually simplest
    /// to just guard against a second call).
    func observe(a2aHost: A2AServerHost, testChatSession: TestChatSession) {
        guard cancellables.isEmpty else { return }
        a2aHost.$pendingApprovals
            .sink { [weak self] items in self?.reconcileA2A(items) }
            .store(in: &cancellables)
        testChatSession.$pendingApprovals
            .sink { [weak self] items in self?.reconcileTestChat(items) }
            .store(in: &cancellables)
    }

    private func reconcileA2A(_ items: [InboundTaskGate.PendingApproval]) {
        let ids = Set(items.map(\.id))
        let isNewArrival = !ids.subtracting(knownA2AIDs).isEmpty
        knownA2AIDs = ids
        // A2A gates a whole TASK, not a named tool — there's no content-free "tool
        // name" to show, so the label stays generic (never the task summary/prompt).
        if isNewArrival { fire(label: "A2A coding task") }
    }

    private func reconcileTestChat(_ items: [TestChatSession.PendingToolApproval]) {
        let ids = Set(items.map(\.id))
        let newIDs = ids.subtracting(knownTestChatIDs)
        knownTestChatIDs = ids
        guard let newID = newIDs.first, let item = items.first(where: { $0.id == newID }) else {
            return
        }
        fire(label: Self.toolLabel(fromTitle: item.title))
    }

    /// Content-free tool label extracted from a permission title. `ToolExecutor.title`
    /// always shapes the string as "<Verb> <argument>" or "<Verb>: <argument>" (e.g.
    /// "Write /path/to/secret.env", "Run: curl -H 'Authorization: …'") — the leading
    /// verb identifies WHAT KIND of action needs approval without exposing the
    /// argument that follows it, which invariant 12 forbids putting in a notification
    /// banner (visible on the lock screen / to anyone glancing at the Mac).
    static func toolLabel(fromTitle title: String) -> String {
        let stop = title.firstIndex(where: { $0 == " " || $0 == ":" }) ?? title.endIndex
        let leading = String(title[..<stop]).trimmingCharacters(in: .whitespaces)
        return leading.isEmpty ? "A tool" : leading
    }

    private func fire(label: String) {
        Task { await self.postNotification(label: label) }
    }

    private func postNotification(label: String) async {
        await requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = "Tool approval pending in Huginn"
        content.body =
            "\(label) is waiting for your approval — it will be denied automatically if you don't respond."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// Ask for notification permission at most once per process — and only once
    /// there's actually something to notify about. If the user later denies it in
    /// System Settings, we don't re-prompt (macOS wouldn't show a second system
    /// prompt anyway); `add(request:)` above just silently does nothing.
    private func requestAuthorizationIfNeeded() async {
        guard !authorizationRequested else { return }
        authorizationRequested = true
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }
}
