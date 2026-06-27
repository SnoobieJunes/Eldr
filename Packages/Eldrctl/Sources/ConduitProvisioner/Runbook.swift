import Foundation

/// The runbook `eldrctl conduit instructions` prints verbatim — the steps the user's AI on
/// the Mac follows to stand up the iPhone-EldrChat ↔ Mac-Huginn conduit. Kept here (not only
/// in `docs/CONDUIT-SETUP.md`) so a test can assert the doc and this stay in sync.
public enum Runbook {
    public static let text: String = """
    ELDR CONDUIT — SETUP RUNBOOK (for the AI driving the Mac)

    Goal: let the user drive THIS Mac's agent (sybilclaw's assistant, or eldr-acp) from
    their iPhone EldrChat, end to end, over the post-quantum relay. You will provision the
    Mac, seed its model token, and hand the user a pairing link. Be honest about each step's
    result; do not claim a step worked unless you saw it succeed.

    PREREQUISITES (verify before you start)
      1. The Mac is LOGGED IN with an unlocked session (auto-login is fine). The conduit's
         long-term keys are WhenUnlockedThisDeviceOnly — at the login window the Keychain is
         unreadable and nothing can be provisioned or served. If the Mac is at loginwindow,
         stop and ask the user to log in / enable auto-login.
      2. You know the phone's OWNER IDENTITY HEX (64 hex chars). The user reads it from
         EldrChat ▸ Settings ▸ (their identity). This is the C-3 gate target: only this
         identity may drive the agent.
      3. The model the agent will use is reachable:
           • responder sybilclaw (default): the local sybilclaw/OpenClaw Gateway is running
             (default port 18789). This routes turns to the user's OWN assistant.
           • responder eldr-acp: a local OpenAI-compatible LLM is up (e.g. LM Studio at
             http://127.0.0.1:1234/v1). This is the proven fallback path.
      4. You have the signed Huginn.app available (default /Applications/Huginn.app), which
         bundles the eldr-node binary the installer ships.

    PROVISION (one command; idempotent — safe to re-run)
        eldrctl install \\
          --target <user@host> \\
          --owner  <64-hex phone identity> \\
          --relay  wss://relay.lerants.com \\
          --responder sybilclaw            # or: eldr-acp
          # add --app /path/to/Huginn.app if it is not in /Applications
          # add --no-app to skip copying the GUI bundle (headless node only)

      This stages Huginn.app + eldr-node to the target, installs them, writes the conduit
      config under ~/.config/eldr-acp, loads a LaunchAgent (chat.eldr.node) that runs the
      node, and prints the pairing link. NO token is sent in this step (it is never put on
      argv or disk).

    SEED THE MODEL TOKEN (only if the model needs one; never written to disk/argv/history)
        eldrctl conduit import-token --target <user@host>
      It prompts for the token on a hidden line and pipes it over SSH straight into the
      node's Keychain. (Local models like LM Studio/Ollama usually need no token — skip this.)

    PAIR THE PHONE
      1. Get the link (also printed by `install`):
             eldrctl conduit pairing-link --target <user@host>
         It looks like:  pqrc:add?npub=npub1…&type=coding_agent&relay=wss%3A%2F%2F…
      2. The user opens EldrChat ▸ new conversation ▸ scans the QR or pastes the link. This
         adds the Mac as a `coding_agent` contact.
      3. In that conversation's details, the user turns ON "Drive this agent from here"
         (remoteDevControlConsent). UNTIL they do, the agent will not act — and the egress
         firewall stays ON. Enabling consent is what turns the firewall OFF for that chat
         (a per-conversation override still wins). This is intentional: trust is granted by
         the user per node, not by the network path.

    VERIFY (state plainly what you observe)
        eldrctl conduit status --target <user@host>
      Confirms the LaunchAgent is loaded and tails the node log. Then have the user send a
      message from the phone and confirm a reply returns. If the responder is sybilclaw and
      the gateway is down, turns will fail with a clear gateway error — start the gateway and
      retry. If you cannot confirm a round-trip on real devices, say so; do not assume it.

    NOTES / HONEST LIMITS
      • The live two-device pairing (Stage 1) and the sybilclaw-gateway round-trip (Stage 2)
        are not yet proven on real hardware. This runbook provisions them; it does not prove
        them. Report what you actually see.
      • The 64 KB inline context cap stays enforced on the relay path. Large content is not
        inlined.
      • Re-running `eldrctl install` converges (it reloads the LaunchAgent); it does not
        duplicate anything.
    """
}
