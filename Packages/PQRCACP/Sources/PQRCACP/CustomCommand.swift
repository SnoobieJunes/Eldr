// SPDX-License-Identifier: Apache-2.0
import Foundation

/// WS-D: one user-defined quick command for the command-chip strips — the
/// phone's interactive terminal and Huginn's Test Chat share this type (each app
/// persists its own list). `autoSend` fires the text as a turn immediately;
/// off = the chip only fills the composer so arguments can be added first.
public struct CustomCommand: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var label: String
    public var text: String
    public var autoSend: Bool

    public init(
        id: String = UUID().uuidString, label: String, text: String, autoSend: Bool = true
    ) {
        self.id = id
        self.label = label
        self.text = text
        self.autoSend = autoSend
    }

    /// Default chips seeded from the enabled agent skills (`/spec`, `/snippet`,
    /// `/html`, …). A slash command wants arguments after it, so seeds fill the
    /// composer (autoSend off) with a trailing space ready to type.
    public static func seeded(fromSkills skills: [String]) -> [CustomCommand] {
        skills.map { name in
            let command = name.hasPrefix("/") ? name : "/\(name)"
            return CustomCommand(
                id: "seed-\(command)", label: command, text: command + " ", autoSend: false)
        }
    }

    /// JSON round-trip helpers so both apps persist identically.
    public static func decodeList(_ data: Data?) -> [CustomCommand]? {
        data.flatMap { try? JSONDecoder().decode([CustomCommand].self, from: $0) }
    }

    public static func encodeList(_ commands: [CustomCommand]) -> Data? {
        try? JSONEncoder().encode(commands)
    }
}
