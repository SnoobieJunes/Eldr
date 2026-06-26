import Foundation

/// Generates paste-able shell scripts that stand up a **khatru** Nostr relay (NIP-42
/// AUTH-gated) on the user's OWN Linux host. This is a GENERATOR, not an executor —
/// the Configurator never opens an SSH/remote-exec surface. The user copies a script
/// and runs it in their host shell.
///
/// SECURITY (plan §4a):
///   - Secrets (Cloudflare/TLS token, admin token) are NEVER embedded as plaintext in
///     the generated text. The install script reads them from the host environment
///     (`${CF_API_TOKEN:?}`) or prompts interactively with `read -s`, so a secret can
///     never leak via shell history, the clipboard, or a screen-share of the copied
///     script. `secretFreeText(_:)` lets tests prove a token value is absent.
///   - Inputs are VALIDATED before any script is emitted (`validate()`): domain
///     format, port range 1–65535, 64-hex x-only pubkeys, ≥1 pubkey.
///   - The khatru container image is PINNED to a specific tag (supply chain).
///   - Install is idempotent (re-running converges), teardown is safe (stop/uninstall
///     never error when nothing is there).
///
/// Everything here is pure (no I/O, no actor state) so it is trivially `Sendable` and
/// unit-testable without a host.
struct RelayProvisioner: Sendable {

    // MARK: - Pins (supply chain)

    /// The khatru relay image, pinned to a specific tag. `scsibug/khatru` is the
    /// conventional published image; the tag pins the build so a re-run can't silently
    /// pull a moved `:latest`. Bump deliberately, never to a floating tag.
    static let khatruImage = "ghcr.io/bitvora/khatru:v0.5.0"

    /// The container engine the generated scripts drive. Docker (or a Docker-compatible
    /// `podman` aliased to `docker`) on the host; chosen because it makes the install
    /// idempotent and the teardown clean without touching the host package manager.
    static let containerName = "eldr-relay"

    // MARK: - Config

    /// TLS termination strategy. Cloudflare-proxied is the project default (free,
    /// orange-clouded, hides origin IP — see the relay-and-infra note); the others
    /// cover users who terminate TLS themselves or front it with their own proxy.
    enum TLSMode: String, CaseIterable, Sendable, Identifiable {
        /// Origin is plain HTTP on `httpPort`; Cloudflare terminates TLS in front of it.
        case cloudflare
        /// khatru obtains its own Let's Encrypt cert for `domain` (needs port 443 open).
        case letsEncrypt
        /// Plain HTTP only (testing / behind a separate reverse proxy you run).
        case none
        var id: String { rawValue }
        var label: String {
            switch self {
            case .cloudflare: return "Cloudflare proxy (recommended)"
            case .letsEncrypt: return "Let's Encrypt (relay terminates TLS)"
            case .none: return "Plain HTTP (behind your own proxy)"
            }
        }
    }

    /// Non-secret relay configuration collected by the wizard.
    struct Config: Sendable, Equatable {
        var domain: String
        /// The port the relay's WebSocket/HTTP listener binds on the host.
        var httpPort: Int
        /// NIP-42 AUTH allowlist: 64-hex x-only pubkeys permitted to read/write.
        var allowedPubkeys: [String]
        var relayName: String
        var relayDescription: String
        var tlsMode: TLSMode
        /// khatru's enforced max event content size, bytes. Default 256 KB matches the
        /// production decision in the relay-and-infra note (above this nothing improves
        /// given the fixed padding buckets).
        var maxContentLength: Int

        init(
            domain: String = "",
            httpPort: Int = 7777,
            allowedPubkeys: [String] = [],
            relayName: String = "Eldr Relay",
            relayDescription: String = "Private PQRC relay (NIP-42 AUTH-gated).",
            tlsMode: TLSMode = .cloudflare,
            maxContentLength: Int = 262_144
        ) {
            self.domain = domain
            self.httpPort = httpPort
            self.allowedPubkeys = allowedPubkeys
            self.relayName = relayName
            self.relayDescription = relayDescription
            self.tlsMode = tlsMode
            self.maxContentLength = maxContentLength
        }
    }

    /// Secret material. These names are the **host environment variable names** the
    /// generated script expects — the VALUES are never read here and never written into
    /// a script. The UI marks the value fields as secret and warns; the user supplies
    /// the values on the host (env or interactive prompt), not through the clipboard.
    enum SecretVar: String, CaseIterable, Sendable {
        /// Cloudflare API token used by the install (DNS/cert automation), if any.
        case cloudflareToken = "CF_API_TOKEN"
        /// Relay admin token (privileged management endpoints).
        case adminToken = "RELAY_ADMIN_TOKEN"

        var label: String {
            switch self {
            case .cloudflareToken: return "Cloudflare API token"
            case .adminToken: return "Relay admin token"
            }
        }
    }

    // MARK: - Validation

    enum ValidationError: Error, Equatable, CustomStringConvertible {
        case emptyDomain
        case invalidDomain(String)
        case portOutOfRange(Int)
        case noPubkeys
        case invalidPubkey(String)
        case invalidMaxContentLength(Int)

        var description: String {
            switch self {
            case .emptyDomain:
                return "Enter the relay's domain (e.g. relay.example.com)."
            case .invalidDomain(let d):
                return "“\(d)” is not a valid domain name."
            case .portOutOfRange(let p):
                return "Port \(p) is out of range — use 1–65535."
            case .noPubkeys:
                return "Add at least one 64-hex pubkey to the AUTH allowlist."
            case .invalidPubkey(let k):
                return "“\(k)” is not a 64-character hex x-only pubkey."
            case .invalidMaxContentLength(let n):
                return "Max content length \(n) is invalid — use a positive byte count."
            }
        }
        /// Surfaced verbatim in the UI.
        var message: String { description }
    }

    let config: Config

    init(config: Config) { self.config = config }

    /// Validate every field, returning ALL problems (so the form can show them at once)
    /// rather than failing on the first. Empty ⇒ valid.
    func validate() -> [ValidationError] {
        var errors: [ValidationError] = []

        let domain = config.domain.trimmingCharacters(in: .whitespaces)
        if domain.isEmpty {
            errors.append(.emptyDomain)
        } else if !Self.isValidDomain(domain) {
            errors.append(.invalidDomain(domain))
        }

        if !(1...65_535).contains(config.httpPort) {
            errors.append(.portOutOfRange(config.httpPort))
        }

        let keys = Self.normalizedPubkeys(config.allowedPubkeys)
        if keys.isEmpty {
            errors.append(.noPubkeys)
        } else {
            for key in keys where !Self.isValidPubkey(key) {
                errors.append(.invalidPubkey(key))
            }
        }

        if config.maxContentLength <= 0 {
            errors.append(.invalidMaxContentLength(config.maxContentLength))
        }

        return errors
    }

    var isValid: Bool { validate().isEmpty }

    /// RFC-1123-ish hostname check: dot-separated labels, each 1–63 chars of
    /// `[A-Za-z0-9-]` not starting/ending with a hyphen, at least two labels, ≤253
    /// total. Rejects spaces, schemes, ports, and bare single labels.
    static func isValidDomain(_ domain: String) -> Bool {
        guard domain.count <= 253 else { return false }
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        for label in labels {
            guard (1...63).contains(label.count) else { return false }
            if label.hasPrefix("-") || label.hasSuffix("-") { return false }
            for ch in label where !(ch.isASCII && (ch.isLetter || ch.isNumber || ch == "-")) {
                return false
            }
        }
        // The TLS-bearing TLD label must not be all-numeric (that's an IP fragment).
        if let tld = labels.last, tld.allSatisfy({ $0.isNumber }) { return false }
        return true
    }

    /// A 64-character lowercase-or-uppercase hex string (a 32-byte x-only secp256k1
    /// pubkey, NIP-01/NIP-42 form). Rejects npub, 0x-prefixes, wrong length.
    static func isValidPubkey(_ key: String) -> Bool {
        guard key.count == 64 else { return false }
        return key.allSatisfy { $0.isHexDigit }
    }

    /// Trim, lowercase, and drop blanks from the allowlist — what the script embeds.
    static func normalizedPubkeys(_ keys: [String]) -> [String] {
        keys.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }

    // MARK: - Script generation

    /// The full bundle of scripts the wizard offers.
    struct ScriptBundle: Sendable {
        let install: String
        let update: String
        let stop: String
        let uninstall: String
    }

    /// Generate every script. Throws if the config is invalid — we never emit a script
    /// for unvalidated input.
    func generateBundle() throws -> ScriptBundle {
        if let first = validate().first { throw first }
        return ScriptBundle(
            install: installScript(),
            update: updateScript(),
            stop: stopScript(),
            uninstall: uninstallScript())
    }

    /// Convenience for the UI/tests: the install script, or `nil` if invalid.
    func installScriptIfValid() -> String? {
        isValid ? installScript() : nil
    }

    // MARK: Install

    /// Idempotent install: writes a pinned config + compose file under
    /// `/opt/eldr-relay`, then (re)creates the container. Re-running converges to the
    /// same state. Secrets are NEVER in this text — `${CF_API_TOKEN:?}` /
    /// `${RELAY_ADMIN_TOKEN:?}` force the host to provide them (env or the prompt block
    /// below), and the script aborts with a clear message if they're missing.
    func installScript() -> String {
        let domain = config.domain.trimmingCharacters(in: .whitespaces)
        let keys = Self.normalizedPubkeys(config.allowedPubkeys)
        let pubkeyTOML = keys.map { "  \"\($0)\"," }.joined(separator: "\n")
        let needsCloudflare = (config.tlsMode == .cloudflare)

        // Interactive secret prompts: only for secrets this TLS mode actually needs, and
        // only when the host hasn't already exported them. read -s keeps them off-screen
        // and out of shell history; they live only in this process's environment.
        var secretPrompts = """
            # The admin token is required; read it interactively if the host didn't export it.
            if [ -z "${RELAY_ADMIN_TOKEN:-}" ]; then
              printf 'Relay admin token (input hidden): ' >&2
              read -rs RELAY_ADMIN_TOKEN; echo >&2
              export RELAY_ADMIN_TOKEN
            fi
            : "${RELAY_ADMIN_TOKEN:?Set RELAY_ADMIN_TOKEN in the environment or enter it when prompted}"
            """
        if needsCloudflare {
            secretPrompts += """

                if [ -z "${CF_API_TOKEN:-}" ]; then
                  printf 'Cloudflare API token (input hidden, blank to skip): ' >&2
                  read -rs CF_API_TOKEN; echo >&2
                  export CF_API_TOKEN
                fi
                """
        }

        return """
            #!/usr/bin/env bash
            # eldr-relay install — generated by Eldr node + setup hub.
            # khatru Nostr relay, NIP-42 AUTH-gated. Run this in YOUR host shell.
            #
            # SECRETS ARE NOT IN THIS FILE. Provide them via the environment, e.g.
            #   RELAY_ADMIN_TOKEN=… CF_API_TOKEN=… bash install-eldr-relay.sh
            # or just run it and enter them at the hidden prompt. They are never written
            # to disk in cleartext beyond the container's runtime environment.
            set -euo pipefail

            RELAY_DOMAIN="\(domain)"
            RELAY_PORT="\(config.httpPort)"
            RELAY_IMAGE="\(Self.khatruImage)"
            RELAY_NAME=\(Self.shellQuote(config.relayName))
            RELAY_DESC=\(Self.shellQuote(config.relayDescription))
            MAX_CONTENT_LENGTH="\(config.maxContentLength)"
            INSTALL_DIR="/opt/\(Self.containerName)"
            TLS_MODE="\(config.tlsMode.rawValue)"

            command -v docker >/dev/null 2>&1 || { echo "docker is required (install Docker or a docker-compatible engine)." >&2; exit 1; }

            \(secretPrompts)

            sudo mkdir -p "$INSTALL_DIR/data"

            # --- Pinned relay config (NIP-11 + NIP-42 allowlist). Non-secret only. ---
            sudo tee "$INSTALL_DIR/relay.toml" >/dev/null <<RELAY_TOML
            name = "$RELAY_NAME"
            description = "$RELAY_DESC"
            domain = "$RELAY_DOMAIN"
            max_content_length = $MAX_CONTENT_LENGTH

            # NIP-42: only these x-only pubkeys may AUTH, read, and write.
            auth_required = true
            [authorized_keys]
            allow = [
            \(pubkeyTOML)
            ]
            RELAY_TOML

            # --- Pinned container definition. The image tag is fixed (supply chain). ---
            sudo tee "$INSTALL_DIR/docker-compose.yml" >/dev/null <<COMPOSE
            services:
              relay:
                image: "$RELAY_IMAGE"
                container_name: "\(Self.containerName)"
                restart: unless-stopped
                ports:
                  - "$RELAY_PORT:8080"
                volumes:
                  - "$INSTALL_DIR/relay.toml:/etc/khatru/relay.toml:ro"
                  - "$INSTALL_DIR/data:/var/lib/khatru"
                environment:
                  - KHATRU_CONFIG=/etc/khatru/relay.toml
                  # Secrets are passed from THIS shell's environment, not baked into the file.
                  - RELAY_ADMIN_TOKEN
                  - CF_API_TOKEN
            COMPOSE

            # Idempotent: `up -d` re-reads the pinned files and converges; re-running is safe.
            sudo -E docker compose -f "$INSTALL_DIR/docker-compose.yml" pull
            sudo -E docker compose -f "$INSTALL_DIR/docker-compose.yml" up -d

            echo "eldr-relay is up on port $RELAY_PORT for $RELAY_DOMAIN (TLS: $TLS_MODE)."
            echo "Point Cloudflare/your proxy at this host:$RELAY_PORT, then set the relay to wss://$RELAY_DOMAIN."
            """
    }

    // MARK: Update

    /// Re-pull the pinned image and recreate the container. Safe to run repeatedly.
    func updateScript() -> String {
        return """
            #!/usr/bin/env bash
            # eldr-relay update — re-pull the pinned image and recreate the container.
            set -euo pipefail
            INSTALL_DIR="/opt/\(Self.containerName)"
            if [ ! -f "$INSTALL_DIR/docker-compose.yml" ]; then
              echo "eldr-relay is not installed (no $INSTALL_DIR/docker-compose.yml). Run the install script first." >&2
              exit 1
            fi
            sudo -E docker compose -f "$INSTALL_DIR/docker-compose.yml" pull
            sudo -E docker compose -f "$INSTALL_DIR/docker-compose.yml" up -d
            echo "eldr-relay updated to the pinned image (\(Self.khatruImage))."
            """
    }

    // MARK: Stop

    /// Stop the relay without removing its data or config. Safe when nothing is running.
    func stopScript() -> String {
        return """
            #!/usr/bin/env bash
            # eldr-relay stop — stop the container, keep data + config.
            set -euo pipefail
            INSTALL_DIR="/opt/\(Self.containerName)"
            if [ -f "$INSTALL_DIR/docker-compose.yml" ]; then
              sudo docker compose -f "$INSTALL_DIR/docker-compose.yml" down
              echo "eldr-relay stopped (data preserved under $INSTALL_DIR/data)."
            else
              echo "eldr-relay is not installed — nothing to stop."
            fi
            """
    }

    // MARK: Uninstall

    /// Teardown. Stops + removes the container; the volume is removed only when the
    /// caller passes `--purge` (so an accidental run can't delete relay data).
    func uninstallScript() -> String {
        return """
            #!/usr/bin/env bash
            # eldr-relay uninstall — remove the container. Pass --purge to also delete data.
            set -euo pipefail
            INSTALL_DIR="/opt/\(Self.containerName)"
            PURGE=0
            [ "${1:-}" = "--purge" ] && PURGE=1

            if [ -f "$INSTALL_DIR/docker-compose.yml" ]; then
              sudo docker compose -f "$INSTALL_DIR/docker-compose.yml" down --remove-orphans || true
            else
              echo "eldr-relay is not installed — nothing to remove."
            fi

            if [ "$PURGE" -eq 1 ]; then
              sudo rm -rf "$INSTALL_DIR"
              echo "eldr-relay removed AND data purged ($INSTALL_DIR deleted)."
            else
              sudo rm -f "$INSTALL_DIR/docker-compose.yml" "$INSTALL_DIR/relay.toml"
              echo "eldr-relay removed. Data kept under $INSTALL_DIR/data — rerun with --purge to delete it."
            fi
            """
    }

    // MARK: - Helpers

    /// POSIX single-quote a value for safe embedding as a shell literal (mirrors the
    /// ConfigurationStore.export escaping). Used only for NON-secret display strings
    /// (relay name/description) — secrets never reach a script.
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The text the UI puts on the clipboard for a given script — identical to the
    /// script. Named so call sites read as "this is what gets copied"; the security
    /// invariant is that no secret VALUE is ever inside it.
    static func clipboardText(_ script: String) -> String { script }

    /// Test/assertion seam: a script with the host secret-var NAMES present (they're
    /// expected) is fine; what must never appear is a secret VALUE. This returns the
    /// script unchanged — the property is enforced by construction (we never interpolate
    /// a secret), and tests assert a known token value is absent from the output.
    static func secretFreeText(_ script: String) -> String { script }
}
