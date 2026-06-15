import Foundation
import PQRCAgent

/// Generates memorable, human-friendly display codenames in the form
/// `adjective-noun-verb-###` (e.g. `clever-otter-glides-204`).
///
/// These names are PURELY LOCAL: each device invents its own name for every
/// person and AI it encounters, and the name is NEVER broadcast or written to
/// the wire (SPEC §0 — names stay client-side, like the rest of the contact
/// record). They exist only so the UI shows something friendlier than
/// `Contact 1a2b3c4d`.
///
/// Two paths, in priority order, and NEITHER leaves the device:
/// 1. On-device Core AI (Apple's `SystemLanguageModel` via FoundationModels) —
///    fully on-device inference, used when the model is available.
/// 2. A deterministic local generator seeded by the identity key — instant,
///    offline, and stable across launches, so the same peer always resolves to
///    the same name even before/without the on-device model.
enum FriendlyName {
    // Curated, all-lowercase, hyphen-safe word lists. Sizes are powers of two
    // so the seed maps to an index with a clean mask.
    static let adjectives = [
        "amber", "brave", "calm", "clever", "cosmic", "crisp", "daring", "dapper",
        "eager", "fancy", "fleet", "gentle", "glad", "golden", "happy", "hidden",
        "jolly", "keen", "lucky", "lunar", "mellow", "merry", "mighty", "nimble",
        "noble", "polar", "proud", "quick", "quiet", "rapid", "royal", "rustic",
        "sage", "sharp", "shy", "silent", "silver", "sleek", "snug", "solar",
        "spry", "stout", "sunny", "swift", "tidy", "vivid", "warm", "wise",
        "witty", "zany", "bold", "bright", "frosty", "humble", "jade", "lush",
        "misty", "plush", "ruby", "spark", "teal", "twin", "wild", "zen",
    ]
    static let nouns = [
        "otter", "falcon", "maple", "comet", "willow", "badger", "heron", "lynx",
        "raven", "bison", "cedar", "ferret", "gecko", "ibis", "jaguar", "koala",
        "lemur", "marten", "newt", "osprey", "puma", "quail", "robin", "seal",
        "tiger", "urchin", "viper", "walrus", "yak", "zebra", "panda", "moth",
        "crane", "drake", "eagle", "finch", "goose", "hawk", "kite", "loon",
        "mink", "orca", "perch", "ram", "swan", "toad", "vole", "wren",
        "asp", "bear", "cub", "doe", "elk", "fox", "gull", "hare",
        "jay", "kit", "owl", "pike", "roe", "stag", "tern", "wolf",
    ]
    static let verbs = [
        "glides", "leaps", "drifts", "soars", "roams", "darts", "dives", "climbs",
        "dashes", "floats", "gallops", "hops", "hums", "jumps", "kicks", "lopes",
        "marches", "nests", "orbits", "paddles", "prowls", "races", "roves", "runs",
        "sails", "scouts", "skips", "slides", "sneaks", "strides", "swims", "trots",
        "wanders", "weaves", "whirls", "zips", "basks", "bounds", "coasts", "creeps",
        "flits", "forages", "grazes", "hovers", "lurks", "perches", "pounces", "rambles",
        "rests", "scampers", "skims", "spins", "sprints", "stalks", "swoops", "tumbles",
        "vaults", "wades", "wiggles", "wins", "yawns", "zooms", "naps", "nods",
    ]

    /// Deterministic, instant, offline name. The same seed always yields the
    /// same name (stable across launches), so a peer's codename never changes
    /// out from under the user. Uses FNV-1a (NOT Swift's per-run-randomized
    /// `Hasher`, which would give a different name every launch).
    static func local(seed: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let adjective = adjectives[Int(hash & 0x3f)]
        let noun = nouns[Int((hash >> 6) & 0x3f)]
        let verb = verbs[Int((hash >> 12) & 0x3f)]
        let digits = Int((hash >> 18) % 1000)
        return String(format: "%@-%@-%@-%03d", adjective, noun, verb, digits)
    }

    /// On-device-first name: asks Core AI to invent a codename when the
    /// on-device model is available and its output matches the expected format;
    /// otherwise falls back to the deterministic local name. Always resolves to
    /// a usable name and NEVER calls a remote API.
    static func generate(seed: String) async -> String {
        if FoundationModelsAgentProvider.isAvailable {
            let instructions = """
                You invent short, friendly, anonymous codenames. Output EXACTLY \
                one codename in the format adjective-noun-verb-### where ### is \
                three digits. All lowercase, hyphen-separated, no spaces, no \
                punctuation, no extra words. Example: clever-otter-glides-204
                """
            if let raw = try? await FoundationModelsAgentProvider.oneShot(
                instructions: instructions, prompt: "Invent one codename."),
                let valid = sanitized(raw)
            {
                return valid
            }
        }
        return local(seed: seed)
    }

    /// Accepts an on-device completion only if it's exactly our format, so a
    /// chatty or malformed reply falls back to the deterministic name instead of
    /// polluting the UI.
    private static func sanitized(_ raw: String) -> String? {
        let candidate = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let pattern = "^[a-z]+-[a-z]+-[a-z]+-[0-9]{3}$"
        guard candidate.range(of: pattern, options: .regularExpression) != nil else { return nil }
        return candidate
    }
}
