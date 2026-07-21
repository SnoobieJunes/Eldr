// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Builders for the ACP wire shapes the agent emits, kept in one place so the
/// agent loop reads cleanly and the exact JSON field names live next to the spec
/// references. Field names match agentclientprotocol.com /protocol/v1/schema.
///
/// `public` (not just `ACPAgent`-internal): `A2AHarness`'s `A2AACPBridge` also speaks the
/// AGENT half of ACP — over an A2A backend instead of a local tool loop — and reuses these
/// same builders rather than hand-duplicating the wire shapes.
public enum ACPWire {

    // MARK: session/update payloads (the `params` of a session/update notification)

    /// `{ sessionId, update: { sessionUpdate: "agent_message_chunk", content: {type:text,text} } }`
    public static func agentMessageChunk(sessionId: String, text: String) -> JSONValue {
        .object([
            "sessionId": .string(sessionId),
            "update": .object([
                "sessionUpdate": .string("agent_message_chunk"),
                "content": .object([
                    "type": .string("text"),
                    "text": .string(text),
                ]),
            ]),
        ])
    }

    /// `{ sessionId, update: { sessionUpdate:"tool_call", toolCallId, title, kind, status, rawInput } }`
    public static func toolCall(
        sessionId: String, toolCallId: String, title: String, kind: String, status: String,
        rawInput: JSONValue
    ) -> JSONValue {
        .object([
            "sessionId": .string(sessionId),
            "update": .object([
                "sessionUpdate": .string("tool_call"),
                "toolCallId": .string(toolCallId),
                "title": .string(title),
                "kind": .string(kind),
                "status": .string(status),
                "rawInput": rawInput,
            ]),
        ])
    }

    /// `{ sessionId, update: { sessionUpdate:"tool_call_update", toolCallId, status, content:[…] } }`
    /// `content` is omitted when `text` is nil (e.g. an in_progress transition).
    public static func toolCallUpdate(
        sessionId: String, toolCallId: String, status: String, contentText: String? = nil,
        isError: Bool = false
    ) -> JSONValue {
        var update: [String: JSONValue] = [
            "sessionUpdate": .string("tool_call_update"),
            "toolCallId": .string(toolCallId),
            "status": .string(status),
        ]
        if let text = contentText {
            // ToolCallContent: either {type:"content",content:{ContentBlock}} or
            // {type:"error",error}. Use the error variant on failure so the editor
            // can render it distinctly.
            let block: JSONValue =
                isError
                ? .object(["type": .string("error"), "error": .string(text)])
                : .object([
                    "type": .string("content"),
                    "content": .object(["type": .string("text"), "text": .string(text)]),
                ])
            update["content"] = .array([block])
        }
        return .object([
            "sessionId": .string(sessionId),
            "update": .object(update),
        ])
    }

    /// `{ sessionId, update: { sessionUpdate:"available_commands_update", availableCommands:[…] } }`
    /// Advertises the agent's slash-commands/skills to the client (it surfaces them
    /// in its command menu). Each entry is `{ name, description, input:{hint} }`.
    public static func availableCommandsUpdate(sessionId: String, commands: [JSONValue]) -> JSONValue {
        .object([
            "sessionId": .string(sessionId),
            "update": .object([
                "sessionUpdate": .string("available_commands_update"),
                "availableCommands": .array(commands),
            ]),
        ])
    }

    /// `{ sessionId, update: { sessionUpdate:"plan", entries:[{content,priority,status}] } }`
    /// The agent's plan for the turn — a checklist the client renders so the user sees
    /// the agent's approach (ACP `PlanEntry`: `content`, `priority` ∈ low|medium|high,
    /// `status` ∈ pending|in_progress|completed). The whole plan is re-sent on each
    /// change (the spec models it as a full snapshot, not a delta), so re-emitting with
    /// updated statuses is how a step flips to `completed`.
    public static func plan(sessionId: String, entries: [(content: String, status: String)]) -> JSONValue {
        let entryObjects = entries.map { entry -> JSONValue in
            .object([
                "content": .string(entry.content),
                // We don't infer per-step priority from the heuristic, so every entry
                // is `medium` (a valid spec value the client may ignore).
                "priority": .string("medium"),
                "status": .string(entry.status),
            ])
        }
        return .object([
            "sessionId": .string(sessionId),
            "update": .object([
                "sessionUpdate": .string("plan"),
                "entries": .array(entryObjects),
            ]),
        ])
    }

    // MARK: Phase D4 — interactive PTY terminal (Eldr extension)

    // These ride the SAME session/update channel as agent_message_chunk/plan, with Eldr
    // `sessionUpdate` variants. They are SEPARATE from the request-based `terminal/*`
    // (`terminal/create` → `wait_for_exit` → `output` → `release`) that one-shot
    // `run_shell` uses (ToolExecutor.runShellViaClient) — that path is untouched. A
    // PERSISTENT interactive terminal streams its output incrementally instead of
    // buffering to EOF, so it needs a push channel the request/response shape can't give.

    /// `{ sessionId, update: { sessionUpdate:"terminal_opened", terminalId, title } }`
    /// Announces a newly-spawned interactive PTY so the phone shows a terminal view.
    public static func terminalOpened(sessionId: String, terminalId: String, title: String) -> JSONValue {
        .object([
            "sessionId": .string(sessionId),
            "update": .object([
                "sessionUpdate": .string("terminal_opened"),
                "terminalId": .string(terminalId),
                "title": .string(title),
            ]),
        ])
    }

    /// `{ sessionId, update: { sessionUpdate:"terminal_output", terminalId, chunk } }`
    /// One incremental slice of the PTY's combined stdout+stderr.
    public static func terminalOutput(sessionId: String, terminalId: String, chunk: String) -> JSONValue {
        .object([
            "sessionId": .string(sessionId),
            "update": .object([
                "sessionUpdate": .string("terminal_output"),
                "terminalId": .string(terminalId),
                "chunk": .string(chunk),
            ]),
        ])
    }

    /// `{ sessionId, update: { sessionUpdate:"terminal_closed", terminalId, exitCode? } }`
    /// The PTY ended (child exited or it was killed). `exitCode` is omitted when unknown
    /// (e.g. killed by signal).
    public static func terminalClosed(sessionId: String, terminalId: String, exitCode: Int?) -> JSONValue {
        var update: [String: JSONValue] = [
            "sessionUpdate": .string("terminal_closed"),
            "terminalId": .string(terminalId),
        ]
        if let exitCode { update["exitCode"] = .int(exitCode) }
        return .object([
            "sessionId": .string(sessionId),
            "update": .object(update),
        ])
    }

    /// `{ sessionId, terminalId, data }` — the `terminal/input` notification params
    /// (write stdin to a live PTY).
    public static func terminalInput(sessionId: String, terminalId: String, data: String) -> JSONValue {
        .object([
            "sessionId": .string(sessionId),
            "terminalId": .string(terminalId),
            "data": .string(data),
        ])
    }

    // MARK: session/request_permission

    /// `{ sessionId, toolCall: { toolCallId, title, kind, status }, options:[…] }`.
    /// Offers a standard allow-once/allow-always/reject-once set.
    public static func requestPermission(
        sessionId: String, toolCallId: String, title: String, kind: String
    ) -> JSONValue {
        .object([
            "sessionId": .string(sessionId),
            "toolCall": .object([
                "toolCallId": .string(toolCallId),
                "title": .string(title),
                "kind": .string(kind),
                "status": .string("pending"),
            ]),
            "options": .array([
                .object([
                    "optionId": .string("allow_once"), "name": .string("Allow"),
                    "kind": .string("allow_once"),
                ]),
                .object([
                    "optionId": .string("allow_always"), "name": .string("Always Allow"),
                    "kind": .string("allow_always"),
                ]),
                .object([
                    "optionId": .string("reject_once"), "name": .string("Reject"),
                    "kind": .string("reject_once"),
                ]),
            ]),
        ])
    }

    /// Interpret a RequestPermissionResponse outcome. Returns true if the user
    /// allowed (selected an allow_* option); false if rejected or cancelled.
    public static func permissionGranted(_ result: JSONValue) -> Bool {
        guard let outcome = result["outcome"] else { return false }
        // Shape: { outcome: { outcome:"selected", optionId:"allow_once" } } | { outcome:"cancelled" }
        if outcome.stringValue == "cancelled" { return false }
        let kind = outcome["outcome"]?.stringValue
        guard kind == "selected" else { return false }
        let optionId = outcome["optionId"]?.stringValue ?? ""
        return optionId.hasPrefix("allow")
    }
}

/// Stop reasons for a prompt turn (the `session/prompt` result).
enum StopReason: String {
    case endTurn = "end_turn"
    case maxTokens = "max_tokens"
    case maxTurnRequests = "max_turn_requests"
    case refusal
    case cancelled
}
