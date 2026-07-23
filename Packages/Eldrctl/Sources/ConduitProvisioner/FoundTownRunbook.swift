// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The runbook `eldrctl found-town instructions` prints verbatim — the steps to stand up a
/// gooseworld "town in a box" (GOOSEWORLD §6 WS-G6): SSH-provision eldr-node + goose + the
/// `eldr-gooseworld` extension, join the hub, and emit a town invite. Kept here (not only in
/// a doc) so a test can assert this and the CLI stay in sync, exactly like `Runbook`.
public enum FoundTownRunbook {
    public static let text: String = """
    ELDR FOUND-TOWN — TOWN-IN-A-BOX RUNBOOK (for the AI/operator provisioning the host)

    Goal: turn a fresh Mac into a gooseworld TOWN — an eldr-node bound to the owner's phone,
    with goose and the eldr-gooseworld extension installed, joined to the hub, ready to pair
    with peer towns over the post-quantum relay. Be honest about each step; do not claim a
    step worked unless you saw it succeed.

    WHAT A TOWN IS (so you provision the right thing)
      A town = the conduit node (eldr-node, owner-gated by the C-3 gate) PLUS goose and the
      eldr-gooseworld MCP extension. The extension is a PIPE to the node over a loopback
      socket; agent keys never leave the node (SPEC §13.5). "Joining the hub" is not a
      separate action: the hub is a relay (GOOSEWORLD §3), so the node joins it and publishes
      its kind-10420 human<->agent binding simply by dialing --hub.

    PREREQUISITES (verify before you start)
      1. The Mac is LOGGED IN with an unlocked session (auto-login is fine). The node's
         long-term keys are WhenUnlockedThisDeviceOnly — at the login window the Keychain is
         unreadable and nothing can be provisioned or served.
      2. You know the town owner's IDENTITY HEX (64 hex chars), read from EldrChat ▸ Settings.
         This is the C-3 gate target: only this identity may drive the town's agent.
      3. goose is ALREADY INSTALLED on the host. found-town does NOT auto-install goose (it
         will not fabricate a download URL); install it from https://block.github.io/goose/
         first. The provisioner verifies goose is present and fails closed if it is not.
      4. You have the signed Huginn.app available (default /Applications/Huginn.app), which
         bundles both the eldr-node and eldr-gooseworld binaries the installer ships.

    PROVISION (one command; idempotent — safe to re-run)
        eldrctl found-town \\
          --target <user@host> \\
          --owner  <64-hex phone identity> \\
          --hub    wss://relay.lerants.com \\
          --goose  ollama                    # provider hint (ollama | openai | anthropic | …)
          # add --app /path/to/Huginn.app if it is not in /Applications
          # add --no-app to skip copying the GUI bundle (headless node only)

      This stages eldr-node + eldr-gooseworld to the target, runs the conduit provision
      (install-huginn.sh — installs the node, writes config, loads the chat.eldr.node
      LaunchAgent), then runs the town layer (installs eldr-gooseworld, writes a goose
      extension stanza), and finally prints the TOWN INVITE. NO token is sent in this step.

    REGISTER THE EXTENSION WITH GOOSE (verify the stanza)
      found-town drops a documented stanza at ~/.config/goose/eldr-gooseworld.extension.yaml.
      goose's config schema is version-dependent, so verify it with `goose configure`. Before
      launching goose, export the gooseworld socket + pairing token the node's settings panel
      shows (they are NEVER written to disk by the installer — C-8).

    SEED THE MODEL TOKEN (only if the responder's model needs one)
        eldrctl conduit import-token --target <user@host>
      Prompts on a hidden line and pipes the token over SSH straight into the node's Keychain
      — never argv, disk, or history.

    EMIT / RE-EMIT THE TOWN INVITE (for a peer town to pair)
        eldrctl found-town invite --target <user@host>
      It looks like:  pqrc:town?npub=npub1…&hub=wss%3A%2F%2F…
      A peer town scans the QR or pastes the link to pair. (The QR is a display concern — the
      scanning surface renders it from this link, the same way the coding_agent pairing flow
      does.) Town pairing routes into the standing-grant flow (GOOSEWORLD §5), NOT coding_agent
      pairing — the `pqrc:town` scheme is what distinguishes them.

    VERIFY (state plainly what you observe)
        eldrctl conduit status --target <user@host>
      Confirms the node LaunchAgent is loaded and tails the node log. Then confirm goose loads
      the eldr-gooseworld extension (it will refuse without a valid token). Report what you
      actually see.

    NOTES / HONEST LIMITS
      • found-town does not auto-install goose; it verifies goose is present and stops if not.
      • The goose extension stanza is best-effort (schema is version-dependent) — verify it.
      • The live cross-town pairing + delegation are proven over the LocalRelaySimulator; the
        two-machine live proof over the real relay is GOOSEWORLD Phase 0 (WS-G1), not yet run.
      • Re-running `eldrctl found-town` converges (it reloads the LaunchAgent and rewrites the
        stanza); it does not duplicate anything.
    """
}
