import Foundation
import PQRCAgent

/// Generates memorable, human-friendly display codenames in the form
/// `Adjective Noun` (e.g. `Clever Otter`).
///
/// These names are PURELY LOCAL: each device invents its own name for every
/// person and AI it encounters, and the name is NEVER broadcast or written to
/// the wire (SPEC §0 — names stay client-side, like the rest of the contact
/// record). They exist only so the UI shows something friendlier than
/// `Contact 1a2b3c4d`.
///
/// Two-word "Adjective Noun" (no trailing number, no verb) reads as an actual
/// name rather than a serial. Earlier names were `adjective-noun-verb-###`,
/// which buried the distinguishing word behind a shared prefix and a noisy
/// numeric suffix — different people looked nearly identical at a glance. The
/// fix for that similarity is the UNIQUENESS pass (`unique(seed:taken:)`): the
/// caller supplies the names already in use, and we deterministically probe
/// forward from the seed-chosen name until we land on one nobody else holds.
///
/// Two paths, in priority order, and NEITHER leaves the device:
/// 1. On-device Core AI (Apple's `SystemLanguageModel` via FoundationModels) —
///    fully on-device inference, used when the model is available.
/// 2. A deterministic local generator seeded by the identity key — instant,
///    offline, and stable across launches, so the same peer always resolves to
///    the same name even before/without the on-device model.
enum FriendlyName {
    // Curated, capitalized word lists. Both are powers of two so the seed maps
    // to an index with a clean mask (128 adjectives × 128 nouns = 16,384 base
    // combinations before the uniqueness probe even kicks in).
    static let adjectives = [
        "Amber", "Brave", "Calm", "Clever", "Cosmic", "Crisp", "Daring", "Dapper",
        "Eager", "Fancy", "Fleet", "Gentle", "Glad", "Golden", "Happy", "Hidden",
        "Jolly", "Keen", "Lucky", "Lunar", "Mellow", "Merry", "Mighty", "Nimble",
        "Noble", "Polar", "Proud", "Quick", "Quiet", "Rapid", "Royal", "Rustic",
        "Sage", "Sharp", "Shy", "Silent", "Silver", "Sleek", "Snug", "Solar",
        "Spry", "Stout", "Sunny", "Swift", "Tidy", "Vivid", "Warm", "Wise",
        "Witty", "Zany", "Bold", "Bright", "Frosty", "Humble", "Jade", "Lush",
        "Misty", "Plush", "Ruby", "Spark", "Teal", "Twin", "Wild", "Zen",
        "Arctic", "Autumn", "Azure", "Breezy", "Bronze", "Cobalt", "Coral", "Cozy",
        "Dawn", "Deep", "Dusky", "Ember", "Fern", "Fiery", "Flint", "Glassy",
        "Hazel", "Honey", "Indigo", "Ivory", "Jazzy", "Lively", "Lone", "Maroon",
        "Maze", "Mint", "Moss", "Nifty", "Onyx", "Opal", "Pearl", "Pine",
        "Plum", "Prime", "Rosy", "Rugged", "Sandy", "Scarlet", "Shady", "Shiny",
        "Slate", "Smoky", "Snowy", "Sober", "Spruce", "Stark", "Steel", "Storm",
        "Sturdy", "Sunlit", "Tawny", "Topaz", "Trusty", "Umber", "Vast", "Velvet",
        "Verdant", "Violet", "Wily", "Windy", "Winter", "Woven", "Zesty", "Zippy",
    ]
    static let nouns = [
        "Otter", "Falcon", "Maple", "Comet", "Willow", "Badger", "Heron", "Lynx",
        "Raven", "Bison", "Cedar", "Ferret", "Gecko", "Ibis", "Jaguar", "Koala",
        "Lemur", "Marten", "Newt", "Osprey", "Puma", "Quail", "Robin", "Seal",
        "Tiger", "Urchin", "Viper", "Walrus", "Yak", "Zebra", "Panda", "Moth",
        "Crane", "Drake", "Eagle", "Finch", "Goose", "Hawk", "Kite", "Loon",
        "Mink", "Orca", "Perch", "Ram", "Swan", "Toad", "Vole", "Wren",
        "Asp", "Bear", "Cub", "Doe", "Elk", "Fox", "Gull", "Hare",
        "Jay", "Kit", "Owl", "Pike", "Roe", "Stag", "Tern", "Wolf",
        "Adder", "Alpaca", "Bat", "Beaver", "Bee", "Boar", "Bream", "Cobra",
        "Condor", "Coyote", "Crow", "Dingo", "Dove", "Egret", "Fawn", "Fennec",
        "Gerbil", "Gibbon", "Gnu", "Grouse", "Hornet", "Husky", "Iguana", "Jackal",
        "Krill", "Lark", "Llama", "Macaw", "Magpie", "Mole", "Moose", "Otterhound",
        "Petrel", "Pony", "Quokka", "Rabbit", "Raccoon", "Salmon", "Shrew", "Skink",
        "Sloth", "Snipe", "Sparrow", "Sprat", "Starling", "Stingray", "Stoat", "Sable",
        "Tapir", "Teal", "Thrush", "Trout", "Turtle", "Vervet", "Wagtail", "Weasel",
        "Whale", "Wombat", "Woodlark", "Yapok", "Yearling", "Zander", "Zebu", "Zorro",
    ]

    /// Deterministic, instant, offline name. The same seed always yields the
    /// same name (stable across launches), so a peer's codename never changes
    /// out from under the user. Uses FNV-1a (NOT Swift's per-run-randomized
    /// `Hasher`, which would give a different name every launch).
    ///
    /// `salt` lets the uniqueness probe re-roll deterministically off the SAME
    /// seed (probe 0 is the canonical name; 1, 2, … are tried only on collision).
    static func local(seed: String, salt: Int = 0) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in (salt == 0 ? seed : "\(seed)#\(salt)").utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let adjective = adjectives[Int(hash & 0x7f)]
        let noun = nouns[Int((hash >> 7) & 0x7f)]
        return "\(adjective) \(noun)"
    }

    /// A locally-unique deterministic name: the seed-chosen `local(seed:)` name
    /// when it's free, otherwise the first forward probe (`salt` 1, 2, …) whose
    /// result isn't already in `taken`. This is the actual fix for "names look
    /// too similar" — distinct people/AIs can no longer collide onto the same
    /// two words. Bounded probing (then a short numeric suffix) guarantees it
    /// always returns even in the pathological case where every combination is taken.
    static func unique(seed: String, taken: Set<String>) -> String {
        guard !taken.isEmpty else { return local(seed: seed) }
        for salt in 0..<256 {
            let candidate = local(seed: seed, salt: salt)
            if !taken.contains(candidate) { return candidate }
        }
        // Astronomically unlikely fallback (would need >256 collisions for one
        // seed): append a short stable suffix so we still hand back a name.
        var suffixed = local(seed: seed)
        var n = 2
        while taken.contains(suffixed) {
            suffixed = "\(local(seed: seed)) \(n)"
            n += 1
        }
        return suffixed
    }

    /// On-device-first name: asks Core AI to invent a codename when the
    /// on-device model is available and its output matches the expected format;
    /// otherwise falls back to the deterministic local name. Always resolves to
    /// a usable name and NEVER calls a remote API. `taken` makes the result
    /// locally unique (the model's pick is re-rolled if it collides).
    static func generate(seed: String, taken: Set<String> = []) async -> String {
        if FoundationModelsAgentProvider.isAvailable {
            let instructions = """
                You invent short, friendly, anonymous codenames. Output EXACTLY \
                one codename in the format "Adjective Noun" — two capitalized \
                words, a single space between them, no numbers, no punctuation, \
                no extra words. Example: Clever Otter
                """
            if let raw = try? await FoundationModelsAgentProvider.oneShot(
                instructions: instructions, prompt: "Invent one codename."),
                let valid = sanitized(raw), !taken.contains(valid)
            {
                return valid
            }
        }
        return unique(seed: seed, taken: taken)
    }

    /// Accepts an on-device completion only if it's exactly our format (two
    /// capitalized words separated by a single space), so a chatty or malformed
    /// reply falls back to the deterministic name instead of polluting the UI.
    private static func sanitized(_ raw: String) -> String? {
        let candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = "^[A-Z][a-z]+ [A-Z][a-z]+$"
        guard candidate.range(of: pattern, options: .regularExpression) != nil else { return nil }
        return candidate
    }
}
