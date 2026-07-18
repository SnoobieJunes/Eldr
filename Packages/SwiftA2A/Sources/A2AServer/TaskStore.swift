import A2ACore
import Foundation

/// Persistence + query seam for tasks. `A2AServer` never assumes anything about
/// durability, so a production deployment can swap in a database-backed store
/// without touching protocol logic.
public protocol TaskStore: Sendable {
    func save(_ task: A2ATask) async
    func task(id: String) async -> A2ATask?
    /// Apply `request`'s `contextId`/`status` filters and `pageSize`/`pageToken`
    /// pagination (and, per task, `historyLength`/`includeArtifacts` trimming).
    func list(matching request: A2AListTasksRequest) async -> A2AListTasksResponse
}

/// The default `TaskStore`: an in-memory dictionary, insertion-ordered for stable
/// pagination. Fine for demos, tests, and single-process servers; state does not
/// survive a restart. No privacy concern in losing it — tasks are transient A2A work
/// items, not the E2EE message content the rest of this workspace treats as sacred.
public actor InMemoryTaskStore: TaskStore {
    /// History entries kept per task; oldest messages are dropped past this cap so a
    /// long-running task's memory footprint stays bounded.
    public static let maxHistoryMessages = 100
    private static let defaultPageSize = 50
    private static let maxPageSize = 100

    private var tasks: [String: A2ATask] = [:]
    /// Insertion order of task ids, for deterministic offset-token pagination.
    private var order: [String] = []

    public init() {}

    public func save(_ task: A2ATask) async {
        var task = task
        if task.history.count > Self.maxHistoryMessages {
            task.history.removeFirst(task.history.count - Self.maxHistoryMessages)
        }
        if tasks[task.id] == nil {
            order.append(task.id)
        }
        tasks[task.id] = task
    }

    public func task(id: String) async -> A2ATask? {
        tasks[id]
    }

    public func list(matching request: A2AListTasksRequest) async -> A2AListTasksResponse {
        var matched = order.compactMap { tasks[$0] }
        if !request.contextId.isEmpty {
            matched = matched.filter { $0.contextId == request.contextId }
        }
        if let status = request.status {
            matched = matched.filter { $0.status.state == status }
        }
        let totalSize = matched.count

        let pageSize = min(max(request.pageSize ?? Self.defaultPageSize, 1), Self.maxPageSize)
        // Simple offset-token pagination: the token is the decimal offset into
        // `matched` where the next page starts. Not resilient to concurrent
        // mutation between pages (fine for the in-memory default store).
        let offset = max(Int(request.pageToken) ?? 0, 0)
        let page = matched.dropFirst(offset).prefix(pageSize)
        let nextOffset = offset + page.count
        let nextPageToken = nextOffset < totalSize ? String(nextOffset) : ""

        let results: [A2ATask] = page.map { task in
            var task = task
            if let historyLength = request.historyLength {
                task.history =
                    historyLength <= 0 ? [] : Array(task.history.suffix(historyLength))
            }
            if request.includeArtifacts == false {
                task.artifacts = []
            }
            return task
        }

        return A2AListTasksResponse(
            tasks: results, nextPageToken: nextPageToken, pageSize: pageSize,
            totalSize: totalSize)
    }
}
