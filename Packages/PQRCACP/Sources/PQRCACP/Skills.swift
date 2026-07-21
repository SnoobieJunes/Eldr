// SPDX-License-Identifier: Apache-2.0
import Foundation

// ACP "available commands" (a.k.a. slash-commands / skills) the agent advertises to
// the client and can execute. ACP advertises commands via a `session/update`
// notification whose `update.sessionUpdate` is `"available_commands_update"` and
// whose `availableCommands` is an array of `{ name, description, input?: {hint} }`
// (agentclientprotocol.com /protocol/v1/slash-commands, /protocol/v1/schema). A
// client invokes one by sending `session/prompt` with the text `"/name <args>"` —
// there is NO dedicated invoke method — so the agent recognizes the leading
// `/name`, strips it, and runs the named skill against the rest of the text.
//
// Each skill here is a FOCUSED behavior: it swaps in a skill-specific system
// instruction (so the model produces a well-structured Markdown spec, a minimal
// runnable code snippet, or a self-contained HTML visualization) while keeping the
// agent's normal tools available (so e.g. the HTML skill can `write_file` the page
// it produced). Skills are model-agnostic — they only change the prompt — so they
// work against any OpenAI-compatible local model behind `LLMClient`.

/// One advertised, executable skill: a slash-command the agent surfaces to the
/// client and a system instruction it applies when that command is invoked.
public struct AgentSkill: Sendable, Equatable {
    /// The command name the client advertises and the user types after `/`
    /// (e.g. `spec`). No leading slash; lower-kebab so it reads as a slash-command.
    public let name: String
    /// Human-readable description shown in the client's command menu.
    public let description: String
    /// Placeholder shown before the user types the command's argument.
    public let inputHint: String
    /// The skill-specific system instruction prepended ahead of the user's text for
    /// this turn. `{cwd}` is substituted with the session working directory so a
    /// skill can reference where a written file would land.
    public let systemInstruction: String

    public init(name: String, description: String, inputHint: String, systemInstruction: String) {
        self.name = name
        self.description = description
        self.inputHint = inputHint
        self.systemInstruction = systemInstruction
    }

    /// The ACP `AvailableCommand` JSON for this skill:
    /// `{ name, description, input: { hint } }`.
    public var availableCommandJSON: JSONValue {
        .object([
            "name": .string(name),
            "description": .string(description),
            "input": .object(["hint": .string(inputHint)]),
        ])
    }
}

/// The catalog of built-in skills plus the enable/disable policy. Constructed once
/// at startup from `AgentConfig`. Backward-compatible default: ALL three skills on.
public struct AgentSkillSet: Sendable, Equatable {
    /// The skills the agent advertises and will execute, in advertise order.
    public let skills: [AgentSkill]

    public init(skills: [AgentSkill]) { self.skills = skills }

    /// True when there's at least one skill to advertise.
    public var isEmpty: Bool { skills.isEmpty }

    /// Look up a skill by its command name (the token after the leading `/`).
    public func skill(named name: String) -> AgentSkill? {
        skills.first { $0.name == name }
    }

    /// The full `availableCommands` array for an `available_commands_update`.
    public var availableCommandsJSON: [JSONValue] { skills.map(\.availableCommandJSON) }

    // MARK: Built-in skills

    /// "Create spec in markdown" — produce a well-structured Markdown specification.
    public static let createSpec = AgentSkill(
        name: "spec",
        description: "Create a spec in Markdown",
        inputHint: "what to specify (feature, API, protocol, …)",
        systemInstruction: """
            You are a precise technical writer. Produce a SINGLE, well-structured \
            Markdown specification document for what the user describes. Requirements:
            - Start with a level-1 title, then a one-paragraph Overview.
            - Use clear section headings (## / ###): Goals, Non-Goals, Requirements, \
            Design / Behavior, Data model or API surface (as relevant), Edge cases, \
            Open questions.
            - Prefer numbered or bulleted requirements that are testable and unambiguous \
            (use MUST/SHOULD/MAY where it adds precision).
            - Use Markdown tables and fenced code blocks where they clarify.
            - Output ONLY the Markdown document — no preamble, no chain-of-thought, no \
            "here is your spec" wrapper. Do not call tools unless the user explicitly \
            asks you to save the file.
            """)

    /// "Generate code snippet" — a minimal, runnable, language-aware snippet.
    public static let generateSnippet = AgentSkill(
        name: "snippet",
        description: "Generate a code snippet",
        inputHint: "what the snippet should do (mention the language)",
        systemInstruction: """
            You are an expert programmer. Produce ONE minimal, correct, runnable code \
            snippet that does what the user asks. Requirements:
            - Infer the language from the request; if none is given, choose Swift and say \
            so in one short line before the code.
            - Output the code in a SINGLE fenced block tagged with the language \
            (```swift, ```python, ```ts, …).
            - Keep it minimal but complete: include the imports/declarations needed to \
            run, and a tiny usage/`main` example when it helps.
            - Add only brief, essential comments. No essay, no chain-of-thought.
            - After the code block, add at most two short lines on how to run it. Do not \
            call tools unless the user explicitly asks you to save the file.
            """)

    /// "Visualize with HTML" — a self-contained, single-file HTML visualization.
    public static let visualizeHTML = AgentSkill(
        name: "html",
        description: "Visualize with a self-contained HTML page",
        inputHint: "what to visualize (data, concept, diagram)",
        systemInstruction: """
            You build self-contained HTML visualizations. Produce ONE complete, \
            standalone HTML document that visualizes what the user describes. \
            Requirements:
            - A full document: <!DOCTYPE html>, <html>, <head> (with <meta charset> and \
            a <title>), and <body>.
            - Everything inline — CSS in a <style> tag and any JS in a <script> tag. NO \
            external resources, CDNs, or network requests (it must render offline by \
            opening the file). Use inline SVG or the Canvas API for graphics; do not \
            reference image files.
            - Make it clear and legible (sensible layout, labels, a heading).
            - Output ONLY the HTML in a single ```html fenced block — no commentary, no \
            chain-of-thought.
            - If, and only if, the user asks to save/open it, call write_file with a \
            `.html` path (relative paths resolve under {cwd}) AFTER presenting the HTML.
            """)

    /// All three built-in skills, in advertise order.
    public static let builtIns: [AgentSkill] = [createSpec, generateSnippet, visualizeHTML]

    /// Build the active set from config:
    ///  - skills disabled entirely → empty set (nothing advertised, prefixes ignored);
    ///  - an explicit allowlist → only those built-ins, in the catalog's order;
    ///  - otherwise → all built-ins.
    public static func from(config: AgentConfig) -> AgentSkillSet {
        guard config.skillsEnabled else { return AgentSkillSet(skills: []) }
        guard let allow = config.skillAllowlist, !allow.isEmpty else {
            return AgentSkillSet(skills: builtIns)
        }
        let wanted = Set(allow)
        return AgentSkillSet(skills: builtIns.filter { wanted.contains($0.name) })
    }

    // MARK: Invocation parsing

    /// Result of inspecting a prompt's text for a leading skill command.
    public struct Invocation: Sendable, Equatable {
        /// The matched skill.
        public let skill: AgentSkill
        /// The user's text with the leading `/name` (and following space) removed.
        public let argument: String
    }

    /// If `text` begins with `/<name>` for a known skill, return that skill and the
    /// remaining argument; otherwise nil. The match is on the FIRST whitespace- or
    /// end-delimited token, so `/spec a REST API` → (spec, "a REST API") and a bare
    /// `/spec` → (spec, ""). A `/unknown` or non-slash text returns nil (handled as
    /// an ordinary prompt). Case-sensitive on the command name (ACP names are
    /// lowercase); a leading slash inside ordinary prose (e.g. a path) only triggers
    /// when it's the very first character AND names a real skill.
    public func invocation(for text: String) -> Invocation? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/"), trimmed.count > 1 else { return nil }
        let afterSlash = trimmed.dropFirst()
        // First token = up to the first whitespace; rest = the argument.
        let token: Substring
        let rest: Substring
        if let spaceIdx = afterSlash.firstIndex(where: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
            token = afterSlash[afterSlash.startIndex..<spaceIdx]
            rest = afterSlash[afterSlash.index(after: spaceIdx)...]
        } else {
            token = afterSlash
            rest = afterSlash[afterSlash.endIndex...]
        }
        guard let skill = skill(named: String(token)) else { return nil }
        return Invocation(
            skill: skill,
            argument: String(rest).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
