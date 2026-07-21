# Security policy

Eldr is an end-to-end-encrypted messenger; security reports are treated as
first-class contributions — the repo's audit-fix history is public on purpose.

## Reporting a vulnerability

**Do not open a public issue for a vulnerability.**

- Preferred: **GitHub → Security → "Report a vulnerability"**
  (<https://github.com/SnoobieJunes/Eldr/security/advisories/new>) — a private
  advisory only the maintainers can see.
- Alternative: email **security@auston.org**.

Include what you can: the affected component (package / app / protocol
section), reproduction steps or a failing test, and impact as you understand
it. A SPEC/NIP citation ([docs/pqrc-SPEC-v1_1.md](docs/pqrc-SPEC-v1_1.md),
[docs/NIP-XX-pqrc.md](docs/NIP-XX-pqrc.md)) speeds triage a lot.

What to expect — solo-maintainer honesty:

- **Acknowledgement within 72 hours**; triage assessment within 7 days.
- **Coordinated disclosure within 90 days** of the report — sooner when the fix
  ships sooner, longer only by mutual agreement.
- Credit in the advisory and changelog, if you want it.
- **No bug bounty yet.** There is no money behind this program today.

## Scope

In scope — anything that breaks a promise the protocol or threat model makes:

- Protocol design and implementation: PQXDH handshake, Double Ratchet, PQ
  rekey, padding/AEAD, gift wrap, binding verification.
- Key handling and at-rest encryption: Keychain / Secure Enclave wrapping,
  envelope-encrypted store, silo passphrases, prekey lifecycle.
- AI-consent enforcement: `ai_window` bypass, an agent passing as human,
  autonomous sends outside a window/invite, MCP codename leaks, egress-firewall
  bypass.
- The coding-agent conduit: path-jail escape, permission-prompt bypass,
  unredacted logs.
- Metadata leaks beyond what [docs/THREAT_MODEL.md](docs/THREAT_MODEL.md)
  already concedes.

Out of scope: what THREAT_MODEL.md explicitly concedes (relays see your IP and
the recipient tag; no deniability; single-device), denial-of-service against
public relays, and issues requiring an already-compromised device.

## Status honesty

Pre-release alpha. **No independent security audit has happened yet.** The test
suite proves the implementation against the spec; it does not replace an audit.
Supported version: `main` only.
