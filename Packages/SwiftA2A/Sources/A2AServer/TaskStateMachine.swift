// SPDX-License-Identifier: Apache-2.0
import A2ACore

/// Legality gate for `A2ATask` status transitions (`TaskState`). `A2AServer` runs
/// every status update — from the executor's `TaskEventSink` and from `CancelTask` —
/// through this before persisting or broadcasting it, so a buggy or malicious
/// executor can never resurrect a terminal task or skip states in a way clients
/// would find surprising.
public enum TaskStateMachine {
    /// Whether a task may move from `from` to `to`.
    ///
    /// Rules (SPEC-equivalent lifecycle, docs/specification.md task-state diagram):
    /// - Terminal states (`COMPLETED`/`FAILED`/`CANCELED`/`REJECTED`) are final:
    ///   nothing transitions out of them.
    /// - `SUBMITTED` -> `WORKING`, any terminal state, or an interrupted state
    ///   (`INPUT_REQUIRED`/`AUTH_REQUIRED`).
    /// - `WORKING` -> any terminal state, an interrupted state, or `WORKING` again
    ///   (repeated progress updates are legal).
    /// - Interrupted (`INPUT_REQUIRED`/`AUTH_REQUIRED`) -> `WORKING` or any terminal
    ///   state (answering the interruption resumes work or ends the task).
    /// - `UNSPECIFIED` -> anything (it is the type's default/absent value, never a
    ///   real "current" state a client should read anything into).
    /// - Unknown wire states (`.unknown`) are not terminal by construction
    ///   (`isTerminal` is false for them), so they fall through to "allow" —
    ///   forward compatibility: a future state we don't recognize should not wedge
    ///   the task machine shut.
    public static func canTransition(from: A2ATaskState, to: A2ATaskState) -> Bool {
        if from.isTerminal { return false }

        switch from {
        case .unspecified:
            return true
        case .submitted, .working:
            switch to {
            case .working: return true
            case .inputRequired, .authRequired: return true
            default: return to.isTerminal
            }
        case .inputRequired, .authRequired:
            switch to {
            case .working: return true
            default: return to.isTerminal
            }
        case .completed, .failed, .canceled, .rejected:
            // Unreachable: `from.isTerminal` already returned above. Kept for
            // exhaustiveness so a future terminal case can't silently fall into
            // the `.unknown` "allow" branch below.
            return false
        case .unknown:
            return true
        }
    }
}
