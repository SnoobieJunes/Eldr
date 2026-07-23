// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Generates the "town-in-a-box" bootstrap (`eldrctl found-town`, GOOSEWORLD §6 WS-G6) and
/// the argv `eldrctl` feeds it. Same doctrine as `ConduitProvisioner`: a pure, `Sendable`,
/// host-free GENERATOR that is unit-testable without a target and NEVER embeds a secret.
///
/// found-town is the conduit provision PLUS the gooseworld layer:
///   1. install eldr-node (REUSED verbatim from `ConduitProvisioner` — `install-huginn.sh`),
///   2. install goose's `eldr-gooseworld` MCP extension binary and register it with goose,
///   3. "join the hub" — which, because the hub IS a relay (GOOSEWORLD §3, "centralized by
///      default, decentralized by capability"), the installed eldr-node does simply by
///      dialing `--hub`; the same dial is what publishes its kind-10420 human↔agent binding.
///   4. emit a TOWN invite (`pqrc:town?…`) — distinct from the coding_agent pairing link — so
///      a PEER town can pair. The QR is a display concern (the scanning surface renders it
///      from the link, exactly as the existing pairing-link flow does); this emits the link.
///
/// `townScript` is STATIC (a constant): every parameter reaches it as a runtime `--flag`, so
/// the text is identical regardless of `Config` and never carries a value — no secret, no
/// host-specific string. Unlike `install-huginn.sh` it is not ALSO shipped as a standalone
/// checked-in file, so it is guarded by shape + no-secret tests rather than a golden file.
public struct FoundTownProvisioner: Sendable {

    /// Non-secret town configuration. Like `ConduitProvisioner.Config` there is no token
    /// field — by design (C-8). The gooseworld pairing token is minted by the node and
    /// seeded out-of-band, never by this generator.
    public struct Config: Sendable, Equatable {
        /// The phone's PQRC identity hex — the C-3 gate target (the town owner). 64 hex.
        public var ownerHex: String
        /// The gooseworld HUB the town joins. Because the hub is a relay (§3), this is also
        /// the relay the node dials for the owner conduit — one wire, two names. `wss://…`.
        public var hubURL: String
        /// A provider HINT for goose (`ollama`, `openai`, `anthropic`, `lm-studio`, …). Not
        /// a secret; validated to a lowercase `[a-z0-9_-]` charset so it is safe in the
        /// generated goose config and argv.
        public var gooseProvider: String
        /// The C-2 jail root the agent's file tools operate in (empty ⇒ remote `$HOME`).
        public var workdir: String
        /// Also copy the signed `Huginn.app` to `/Applications` (full-app install).
        public var installApp: Bool
        /// Where the payload (eldr-node, eldr-gooseworld, Huginn.app) is staged on the
        /// TARGET. `eldrctl` scp's it here before running the scripts.
        public var payloadDir: String

        public init(
            ownerHex: String,
            hubURL: String = "wss://relay.lerants.com",
            gooseProvider: String = "ollama",
            workdir: String = "",
            installApp: Bool = true,
            payloadDir: String = ""
        ) {
            self.ownerHex = ownerHex
            self.hubURL = hubURL
            self.gooseProvider = gooseProvider
            self.workdir = workdir
            self.installApp = installApp
            self.payloadDir = payloadDir
        }
    }

    public enum ValidationError: Error, Equatable, CustomStringConvertible {
        case invalidHub(String)
        case invalidProvider(String)

        public var description: String {
            switch self {
            case .invalidHub(let v):
                return
                    "--hub must be a ws:// or wss:// URL with no whitespace or shell "
                    + "metacharacters; got \"\(v)\"."
            case .invalidProvider(let v):
                return "--goose provider must be lowercase [a-z0-9_-] (1–40 chars); got \"\(v)\"."
            }
        }
    }

    public let config: Config
    public init(config: Config) { self.config = config }

    /// The conduit sub-config this town layers on. The hub IS the relay (§3), so the node
    /// dials `hubURL` for both the owner conduit and town traffic. Reuses the proven
    /// `ConduitProvisioner` provision unchanged — found-town adds a layer, it does not fork
    /// the node install.
    public func conduitConfig() -> ConduitProvisioner.Config {
        ConduitProvisioner.Config(
            ownerHex: config.ownerHex,
            relayURL: config.hubURL,
            workdir: config.workdir,
            responder: .sybilclaw,  // owner-chat responder; configured exactly like `install`.
            installApp: config.installApp,
            payloadDir: config.payloadDir)
    }

    /// Validate inputs before any SSH happens. Fails closed on a bad owner / hub / provider,
    /// mirroring `ConduitProvisioner.validate`.
    ///
    /// Owner + hub SHAPE are validated by the proven conduit validator (the hub is the
    /// relay). The two town-specific checks below are STRICTER than the shell prefix test:
    /// they whitelist the charset so neither value can carry a shell metacharacter into the
    /// generated goose config, the town-invite link, or the argv.
    public func validate() throws {
        // Owner hex + relay(=hub) prefix + gateway-port, via the conduit validator. A bad
        // owner surfaces here as `ConduitProvisioner.ValidationError.invalidOwner`, so
        // found-town rejects exactly what `install` does.
        try ConduitProvisioner(config: conduitConfig()).validate()

        let hub = config.hubURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isSafeHubURL(hub) else { throw ValidationError.invalidHub(hub) }

        let provider = config.gooseProvider.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isSafeProvider(provider) else { throw ValidationError.invalidProvider(provider) }
    }

    /// Whether `url` is a safe hub/relay value. `ConduitProvisioner.validate` only checks the
    /// `ws://`/`wss://` prefix; this ADDS a charset whitelist so a prefix-valid-but-hostile
    /// value like `wss://h$(id)` or `wss://h;rm -rf ~` is refused before it can reach the
    /// generated goose config, the town-invite link, or a bare argv element.
    public static func isSafeHubURL(_ url: String) -> Bool {
        guard url.hasPrefix("ws://") || url.hasPrefix("wss://"), url.count <= 512 else {
            return false
        }
        let allowed = Set(
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-:/?=&%~+")
        return url.allSatisfy { allowed.contains($0) }
    }

    /// Whether `provider` is a safe goose provider hint: lowercase `[a-z0-9_-]`, 1–40 chars.
    /// Rejects whitespace and shell metacharacters, since it lands in a generated config and
    /// argv.
    public static func isSafeProvider(_ provider: String) -> Bool {
        guard !provider.isEmpty, provider.count <= 40 else { return false }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-_")
        return provider.allSatisfy { allowed.contains($0) }
    }

    /// The argv `eldrctl` passes to `townScript` on the target (AFTER `install-huginn.sh` has
    /// already staged + loaded eldr-node). Order is stable for testability. No secret.
    public func townScriptArguments() -> [String] {
        var args: [String] = [
            "--hub", config.hubURL,
            "--goose-provider", config.gooseProvider,
        ]
        if !config.payloadDir.isEmpty { args += ["--payload", config.payloadDir] }
        return args
    }

    /// The TOWN invite a PEER town scans/pastes to pair. Distinct scheme path (`pqrc:town`,
    /// not `pqrc:add`) so the scanning client routes it to town-pairing (the standing-grant
    /// flow, GOOSEWORLD §5) rather than coding_agent pairing. `npub` is already bech32; this
    /// only formats. Same encoding discipline as `ConduitProvisioner.pairingLink`.
    public static func townInvite(npub: String, hub: String?) -> String {
        var link = "pqrc:town?npub=\(npub)"
        if let hub, !hub.isEmpty,
            let encoded = hub.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        {
            link += "&hub=\(encoded)"
        }
        return link
    }

    /// Extract the `npub` from an `eldr-node --print-pairing-link` output
    /// (`pqrc:add?npub=<npub>&type=coding_agent[&relay=…]`). The node has no
    /// `--print-town-invite` mode yet (that would require editing EldrNode — a documented
    /// follow-up), so found-town derives the town invite CONTROLLER-SIDE from the npub the
    /// node already prints, then formats it with `townInvite`. Pure + testable.
    ///
    /// - Returns: the npub, or nil if the link has no non-empty `npub` field.
    public static func npub(fromPairingLink link: String) -> String? {
        guard let query = link.split(separator: "?", maxSplits: 1).last else { return nil }
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2, kv[0] == "npub" {
                let value = String(kv[1])
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    /// The TOWN layer of the bootstrap, run AFTER `ConduitProvisioner.installScript` has
    /// already staged + loaded eldr-node. STATIC: everything is a runtime `--flag`, so this
    /// never carries a `Config` value (and never a secret).
    ///
    /// HONESTY (GOOSEWORLD house rule; the `HarnessDescriptor` provisional/verified split):
    /// every step is marked GENUINE or PLACEHOLDER. In particular this script does NOT
    /// auto-install goose — fabricating a download-and-pipe-to-bash for a release URL it
    /// cannot verify is exactly the supply-chain step this project refuses to ship — it
    /// verifies goose is present and fails closed with a pointer to goose's official
    /// installer. The goose-config registration is written as a documented, best-effort
    /// stanza (goose's schema is version-dependent) next to goose's config rather than
    /// clobbering it.
    public static let townScript: String = #"""
    #!/bin/bash
    # found-town.sh — the TOWN layer of `eldrctl found-town` (GOOSEWORLD §6 WS-G6).
    #
    # Generated by FoundTownProvisioner (Packages/Eldrctl). Runs on the TARGET, AFTER
    # install-huginn.sh has already staged + loaded eldr-node (the conduit provision). This
    # script does ONLY the gooseworld-specific steps; it does not touch the node install.
    #
    # SECRET-FREE: the gooseworld pairing token is NEVER an argument or a written value. The
    # node mints it; the node's settings panel shows it. The extension reads
    # ELDR_GOOSEWORLD_SOCKET and ELDR_GOOSEWORLD_TOKEN from its environment at launch.
    set -euo pipefail

    HUB=""; GOOSE_PROVIDER="ollama"; PAYLOAD=""; DRY_RUN="0"
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --hub) HUB="$2"; shift 2;;
        --goose-provider) GOOSE_PROVIDER="$2"; shift 2;;
        --payload) PAYLOAD="$2"; shift 2;;
        --dry-run) DRY_RUN="1"; shift;;
        *) echo "found-town.sh: unknown argument: $1" >&2; exit 2;;
      esac
    done

    die() { echo "found-town.sh: $1" >&2; exit 2; }

    # --- Validate (mirrors FoundTownProvisioner.validate) -----------------------------
    [ -n "$HUB" ] || die "--hub <wss://...> is required (the gooseworld hub the town joins)."
    case "$HUB" in ws://*|wss://*) ;; *) die "--hub must start with ws:// or wss://." ;; esac
    case "$GOOSE_PROVIDER" in *[!a-z0-9_-]*) die "--goose-provider must be lowercase [a-z0-9_-]." ;; esac

    BIN_DIR="$HOME/.local/bin"
    GOOSE_CFG_DIR="$HOME/.config/goose"
    mkdir -p "$BIN_DIR" "$GOOSE_CFG_DIR"

    # --- 1. goose preflight — GENUINE, fail-closed. We do NOT auto-install goose. ------
    # Fabricating a download-and-pipe-to-bash for a release URL we cannot verify is exactly
    # the supply-chain step this project refuses to ship. If goose is absent we STOP and
    # point at goose's OFFICIAL installer rather than invent one.
    if ! command -v goose >/dev/null 2>&1; then
      die "goose is not installed on this host. found-town does not auto-install goose; install it from https://block.github.io/goose/ (or your package manager), then re-run."
    fi
    echo "==> goose found: $(command -v goose)  (provider hint: $GOOSE_PROVIDER)"

    # --- 2. Install the staged eldr-gooseworld extension binary — GENUINE --------------
    GOOSE_SRC=""
    if [ -n "$PAYLOAD" ] && [ -f "$PAYLOAD/eldr-gooseworld" ]; then GOOSE_SRC="$PAYLOAD/eldr-gooseworld"; fi
    [ -n "$GOOSE_SRC" ] || die "eldr-gooseworld binary not found. Pass --payload <dir containing eldr-gooseworld>."
    echo "==> Installing eldr-gooseworld -> $BIN_DIR/eldr-gooseworld"
    if [ "$DRY_RUN" = "0" ]; then install -m 0755 "$GOOSE_SRC" "$BIN_DIR/eldr-gooseworld"; fi

    # --- 3. Register the extension with goose — BEST-EFFORT (PLACEHOLDER schema) --------
    # goose extensions are MCP servers registered in goose's config. The exact schema is
    # goose-version-dependent, so we DROP a documented stanza NEXT TO goose's config rather
    # than clobber config.yaml, and print the `goose configure` step to verify it. NO token
    # value here (C-8) — the extension reads ELDR_GOOSEWORLD_SOCKET and the pairing token
    # from its environment at launch (the node's settings panel shows both).
    STANZA="$GOOSE_CFG_DIR/eldr-gooseworld.extension.yaml"
    umask 077
    cat > "$STANZA" <<'YAMLEOF'
    # eldr-gooseworld — Eldr's secure inter-town transport, as a goose (MCP) extension.
    # PLACEHOLDER SCHEMA: verify against your goose version with `goose configure`.
    # The pairing token is NOT stored here (C-8). Export both from the node's settings
    # before launching goose:
    #   export ELDR_GOOSEWORLD_SOCKET   (socket path shown by the node)
    #   export ELDR_GOOSEWORLD_TOKEN    (pairing token shown by the node's settings panel)
    extensions:
      eldr-gooseworld:
        type: stdio
        cmd: eldr-gooseworld
        enabled: true
        # cmd inherits ELDR_GOOSEWORLD_SOCKET + the pairing token from the environment.
    YAMLEOF
    echo "==> Wrote goose extension stanza -> $STANZA  (verify with: goose configure)"

    # --- 4. Hub join + kind-10420 binding — done BY eldr-node, stated for the operator -
    # The hub IS a relay (GOOSEWORLD §3), so the eldr-node the conduit step already loaded
    # JOINS THE HUB simply by dialing --hub, and that same dial is what publishes its
    # kind-10420 human<->agent binding. There is no extra step for this script to perform.
    echo "==> eldr-node joins the hub ($HUB) and publishes its kind-10420 binding by dialing it."

    cat <<'HINT'

    Next:
      1. Export the gooseworld socket + token (the node's settings panel shows both), then
         start goose so it loads the eldr-gooseworld extension.
      2. Emit the TOWN invite for a peer town to pair:
             eldrctl found-town invite --target <user@host>
      3. Seed the model token if the responder needs one:
             eldrctl conduit import-token --target <user@host>
    HINT
    """#
}
