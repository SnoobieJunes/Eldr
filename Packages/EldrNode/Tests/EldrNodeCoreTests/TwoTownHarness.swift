// SPDX-License-Identifier: Apache-2.0
import Foundation
import PQRCACP
import Testing

@testable import EldrNodeCore
@testable import PQRCCore
@testable import PQRCNostr

// GOOSEWORLD Phase-0 substitute (private/GOOSEWORLD.md §7). The live two-machine proof
// (WS-G1) needs a SECOND Mac the owner does not have, so the whole cross-town Task plane
// is otherwise unverified. This harness stands TWO full towns up in one process over ONE
// `LocalRelaySimulator` and closes the loop end to end:
//
//   Town A (initiator)  ──A2A `message/send`──▶  relay  ──▶  Town B `EldrNodeCore.serve`
//        ▲                                                          │ (grant-backed gate)
//        └──────────  agent-labeled A2A reply  ◀── per-peer transport ◀── TownA2AService
//
// Everything that matters is real: real `PQRCMessenger`s with the gift-wrapped Double
// Ratchet, the real `serve` loop, the real `StandingGrantTownAuthorizer`, and a real
// human-signed `StandingGrant`. The ONLY simplifications, both stated in the report, are
// that Town B's service is a minimal well-formed A2A responder (not a live goose flock)
// and that the messengers share an in-process relay instead of relay.lerants.com.
//
// ## Which side signs what (the real semantics of `serve`, not a guess)
//
// `serve` consults `townAuthorizer` for every inbound A2A frame. The grant-backed
// authorizer (`StandingGrantTownAuthorizer`) admits a peer iff **Town B's OWNER** — the
// human whose node this is, i.e. the same identity `serve` pins for C-3 — currently holds
// a live, owner-signed `StandingGrant` naming **Town A** as its `peer` on the `.delegate`
// plane. So on the ADMISSION side it is Town B that signs, naming Town A. (The symmetric
// SEND-side grant — Town A's owner signing a grant naming Town B, consulted by
// `AgentEngine.authorizeTownSend` with its day-budget math — lives in PQRCAgent, which is
// not linked into this test target; it is proven exhaustively by that package's
// `StandingGrantGateTests`, and audited by reading. See the report.)

#if os(macOS)

// MARK: - Town A's client-side A2A receive path (the piece nobody had wired)

/// Drains Town A's messenger's single event stream, routes A2A-framed bodies from the
/// serving node into a receive-only `RelayA2ATransport`, and surfaces the reassembled
/// lines. This is the initiator half of the loop: `serve` proves the node ADMITS and
/// ANSWERS; this proves the answer actually lands back at the town that asked, byte-exact.
///
/// `acceptFrom` pins the sender: only A2A frames from the SERVING NODE are delivered, so a
/// stray frame from any other identity on the relay could never masquerade as the reply —
/// the client-side mirror of the node's own per-peer isolation.
actor TownAInbox {
    private let transport: RelayA2ATransport
    private let acceptFrom: String
    private var lines: [String] = []
    private var streamTask: Task<Void, Never>?
    private var drainTask: Task<Void, Never>?

    init(acceptFrom peerHex: String, maxFrameBytes: Int) {
        self.acceptFrom = peerHex
        // Receive-only: this transport never sends, it only reassembles the node's replies.
        self.transport = RelayA2ATransport(maxFrameBytes: maxFrameBytes) { _ in }
    }

    func attach(_ stream: AsyncStream<MessengerEvent>) {
        let transport = self.transport
        let accept = self.acceptFrom
        drainTask = Task { [weak self] in
            for await line in transport.inboundLines() {
                if Task.isCancelled { break }
                await self?.record(line)
            }
        }
        streamTask = Task {
            for await event in stream {
                if Task.isCancelled { break }
                guard case .message(let m) = event else { continue }
                guard m.senderIdentityHex == accept else { continue }  // isolation: node only
                guard RelayA2ATransport.isA2AFrame(m.body.text) else { continue }
                await transport.deliverInbound(m.body.text)
            }
        }
    }

    private func record(_ line: String) { lines.append(line) }

    /// Every A2A line reassembled from the node so far.
    func received() -> [String] { lines }

    /// Poll until `n` reply lines have arrived (the drain is a detached task).
    func waitForLines(_ n: Int, timeoutMillis: Int = 5_000) async -> Bool {
        var waited = 0
        while lines.count < n && waited < timeoutMillis {
            try? await Task.sleep(for: .milliseconds(10))
            waited += 10
        }
        return lines.count >= n
    }

    /// Settle a fixed beat, then report the count — for "no reply must come back" asserts,
    /// where waiting for a line that should never arrive is the only way to be sure.
    func countAfterSettling(millis: Int = 700) async -> Int {
        try? await Task.sleep(for: .milliseconds(millis))
        return lines.count
    }

    func stop() {
        streamTask?.cancel()
        drainTask?.cancel()
        transport.close()
    }
}

// MARK: - A live grant set that a test can revoke mid-run

/// The set of currently-live, owner-signed grants the `StandingGrantTownAuthorizer` reads
/// on EACH frame. Mutable so a test can model a revocation upstream (the engine's
/// `revokeMyStandingGrant` removes the record) as a removal here, and then prove that the
/// authorizer — re-invoked per frame, with no cache — denies the very next delegation.
actor MutableGrantSet {
    private var grants: [StandingGrant]
    init(_ grants: [StandingGrant]) { self.grants = grants }
    func current() -> [StandingGrant] { grants }
    func revoke() { grants = [] }
    func set(_ g: [StandingGrant]) { grants = g }
}

// MARK: - The two-town stage

/// The parties + relay + Town A inbox, before `serve` is started. Kept separate from the
/// serve launch because the grant-backed authorizer must be built from these deterministic
/// identities (Town B's owner signs, Town A is the named peer) BEFORE `serve` begins.
struct TwoTownParties {
    let relay: LocalRelaySimulator
    /// Town B's human owner: signs the admission grant AND is `serve`'s C-3 owner pin.
    let ownerB: NodePersona
    /// Town B's headless daemon: runs `EldrNodeCore.serve`.
    let nodeB: NodePersona
    /// Town A: the initiating town that delegates a bead and awaits the reply.
    let townA: NodePersona
    /// An unpinned bystander town — a verified contact of the node, so its frames DECRYPT,
    /// leaving the grant as the only thing separating it from Town A.
    let stranger: NodePersona
    /// Town A's client-side receive path (already attached to Town A's stream).
    let inbox: TownAInbox
}

/// Stand up the parties: four deterministic personas over one relay, node↔(townA,stranger)
/// mutually verified so every frame below decrypts at the node, and Town A's inbox attached
/// to its own stream. Does NOT establish the ratchet sessions or start `serve` yet — the
/// node's messenger stream is owned solely by `serve`, so sessions can only settle after
/// `serve` is running (call `settleTownSession` then).
func makeTwoTownParties(seedBase: UInt64, maxFrameBytes: Int) async throws -> TwoTownParties {
    let relay = LocalRelaySimulator()
    let ownerB = try await NodePersona.make(
        name: "OwnerB", seedByte: "0a", seed: seedBase, transports: [await relay.connect()])
    let nodeB = try await NodePersona.make(
        name: "NodeB", seedByte: "0b", seed: seedBase &+ 1, transports: [await relay.connect()])
    let townA = try await NodePersona.make(
        name: "TownA", seedByte: "0c", seed: seedBase &+ 2, transports: [await relay.connect()])
    let stranger = try await NodePersona.make(
        name: "Stranger", seedByte: "0d", seed: seedBase &+ 3, transports: [await relay.connect()])

    for peer in [townA, stranger] {
        await nodeB.messenger.addContact(try peer.asContact())
        await peer.messenger.addContact(try nodeB.asContact())
    }

    let inbox = TownAInbox(acceptFrom: nodeB.identityHex, maxFrameBytes: maxFrameBytes)
    await inbox.attach(try await townA.messenger.start())

    return TwoTownParties(
        relay: relay, ownerB: ownerB, nodeB: nodeB, townA: townA, stranger: stranger, inbox: inbox)
}

/// Launch Town B's `serve` loop. The town plane is on iff BOTH the authorizer and a service
/// are supplied — exactly the two-switch contract `serve` documents. `llm` is injectable so
/// the confused-deputy test can count agent turns (a `CountingLLM`) and prove a town frame
/// never reaches the coding agent.
func startTownServe(
    core: EldrNodeCore,
    nodeMessenger: PQRCMessenger,
    ownerHex: String,
    maxFrameBytes: Int,
    llm: any LLMClient,
    authorizer: any TownAuthorizer,
    service: any TownA2AService,
    workdir: String
) -> Task<Void, Never> {
    Task {
        await core.serve(
            messenger: PQRCNodeMessenger(messenger: nodeMessenger),
            ownerIdentityHex: ownerHex,
            maxFrameBytes: maxFrameBytes,
            llm: llm,
            toolEnvironment: ToolEnvironment(workdir: workdir, baseEnvironment: [:]),
            config: .default,
            streamingEnabled: false,
            descriptor: .builtIn,
            townAuthorizer: authorizer,
            townService: service)
    }
}

/// Establish `peer`'s ratchet session with the node and wait until the node has actually
/// built the responder session (decrypted the handshake). Only then does a subsequent frame
/// from `peer` decrypt at the node and reach the gate — so the gate is the ONLY thing that
/// can drop it, never a silent decrypt failure. Call once per peer, SEQUENTIALLY: two
/// initiators fetching a bundle concurrently can pick the same one-time prekey and the
/// second handshake fails for a reason unrelated to the gate (the documented prekey race).
func settleTownSession(
    nodeB: NodePersona, peer: NodePersona, timeoutMillis: Int = 4_000
) async throws {
    try await peer.messenger.establishSession(
        with: try nodeB.asContact(), bundle: try await nodeB.prekeyManager.publicBundle(),
        firstMessage: MessageBody(text: "handshake", sentAt: 1))
    var waited = 0
    while waited < timeoutMillis {
        if await nodeB.messenger.hasSession(peerIdentityHex: peer.identityHex) { return }
        try? await Task.sleep(for: .milliseconds(10))
        waited += 10
    }
    throw NodeTimedOut(what: "\(peer.name) session at node did not settle")
}

/// Frame + send ONE A2A line from `town` to the node over the relay, returning the framer
/// (keep it alive until the line is delivered, then `close()`). `seq` gives each carried
/// chunk a distinct `sentAt` so multi-chunk lines are distinct ratchet messages.
@discardableResult
func delegateA2A(
    line: String, from town: NodePersona, toNodeHex nodeHex: String,
    seq: NodeSeq, maxFrameBytes: Int, salt: String
) -> RelayA2ATransport {
    let framer = RelayA2ATransport(maxFrameBytes: maxFrameBytes, instanceSalt: salt) { framed in
        try? await town.messenger.send(
            MessageBody(text: framed, sentAt: await seq.next()), to: nodeHex)
    }
    framer.send(line)
    return framer
}

/// Frame + send ONE ACP line from `town` to the node — the confused-deputy probe. A
/// byte-valid `ACP1|` frame that DOES decrypt at the node; only C-3 (owner-only) stands
/// between it and the coding agent, and a town's A2A grant must not move that gate.
@discardableResult
func sendACPFrame(
    line: String, from town: NodePersona, toNodeHex nodeHex: String,
    seq: NodeSeq, maxFrameBytes: Int, salt: String
) -> RelayACPTransport {
    let framer = RelayACPTransport(maxFrameBytes: maxFrameBytes, instanceSalt: salt) { framed in
        try? await town.messenger.send(
            MessageBody(text: framed, sentAt: await seq.next()), to: nodeHex)
    }
    framer.send(line)
    return framer
}

// MARK: - A2A helpers

/// The `result.role` of an A2A JSON-RPC response line, or nil if absent — used to prove the
/// reply Town A receives is labeled `"agent"` (invariant 8: an agent-authored reply must be
/// honestly attributable; a human label under an agent's answer is a protocol violation).
func a2aResultRole(_ jsonLine: String) -> String? {
    guard let data = jsonLine.data(using: .utf8),
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let result = obj["result"] as? [String: Any],
        let role = result["role"] as? String
    else { return nil }
    return role
}

/// A well-formed A2A `message/send` request — Town A's delegation of a bead to Town B.
func delegationLine(id: Int, task: String) -> String {
    #"{"jsonrpc":"2.0","id":\#(id),"method":"message/send","params":{"message":{"role":"user","#
        + #""parts":[{"kind":"text","text":"delegate \#(task)"}]}}}"#
}

/// A well-formed A2A response whose result `Message` is labeled `role:"agent"` — the shape a
/// town service returns so the reply is honestly agent-attributable end to end.
func agentReplyLine(id: Int, text: String) -> String {
    #"{"jsonrpc":"2.0","id":\#(id),"result":{"kind":"message","role":"agent","#
        + #""parts":[{"kind":"text","text":"\#(text)"}]}}"#
}

#endif  // os(macOS)
