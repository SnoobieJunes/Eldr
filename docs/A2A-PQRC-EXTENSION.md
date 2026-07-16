# A2A over PQRC: an end-to-end-encrypted, serverless transport binding for the A2A protocol

- **Extension URI:** `https://eldr.app/ext/a2a-pqrc-e2ee/v1`
- **Type:** Transport-binding profile extension
- **Status:** Draft
- **Protocol version covered:** A2A v1.0
- **Implementation:** Eldr (Swift) — [`SwiftA2A`](../Packages/SwiftA2A) (core A2A types, JSON-RPC, HTTP transport) tunneled over [`PQRCNostr`](../Packages/PQRCNostr)'s `RelayA2ATransport`
- **Intended venue:** submission to the a2aproject community as a registered extension

## 0. Status of this document

This is a Draft. It describes a working implementation; it has not gone through
a2aproject's extension review process. Feedback and interoperability reports are
welcome before it is proposed for that process.

The key words **MUST**, **MUST NOT**, **REQUIRED**, **SHALL**, **SHALL NOT**,
**SHOULD**, **SHOULD NOT**, **RECOMMENDED**, **MAY**, and **OPTIONAL** in this
document are to be interpreted as described in RFC 2119 and RFC 8174, when, and
only when, they appear in all capitals.

This document assumes familiarity with the [A2A specification](https://a2a-project.github.io/A2A/)
(the "core specification") — in particular the JSON-RPC transport binding, the
`AgentCard`, `AgentInterface`, and `SecurityScheme` objects, and the extension
mechanism (`AgentCard.capabilities.extensions`). It does not restate core A2A
semantics (task lifecycle, message/artifact shapes, method contracts) except
where this binding modifies them.

## 1. Motivation

A2A's standard transport bindings (JSON-RPC/HTTP, gRPC, HTTP+JSON) share an
assumption: the server side runs on a routable HTTPS endpoint, discoverable at a
public `/.well-known/agent-card.json` URL, authenticated via an OAuth-style
`SecurityScheme`. That assumption excludes a whole class of agents this profile
targets: **personal agents running on a user's own device**, behind NAT, with no
public DNS name, no TLS certificate, and no interest in exposing an HTTP listener
to the internet at all.

Even where a personal agent *could* stand up a server (a dynamic-DNS tunnel, a
reverse proxy), the standard bindings leak metadata neither party may want to
leak:

- the agent card is served at a **public, guessable well-known URL** — anyone who
  finds it learns the agent exists, its skills, and its provider;
- the **client's IP address** is visible to the server on every request;
- for push notifications, the client must hand the server a **webhook URL** — its
  own reachable address — inverting the exposure problem onto the caller.

This profile defines an alternative transport binding: A2A tunneled over
**PQRC** (Post-Quantum Ratcheted Conversations), a decentralized, end-to-end
encrypted messaging protocol running over the Nostr relay network. Two PQRC
peers who have already mutually paired (verified each other's identity binding)
can exchange A2A JSON-RPC traffic with:

- **no server owned by either party** — both sides are symmetric relay clients;
- **end-to-end encryption** — gift wrap (NIP-59-style) + a Double Ratchet + periodic
  post-quantum (ML-KEM-768) rekeying, the same session machinery PQRC uses for
  human chat;
- **a relay that sees ciphertext only** — no plaintext JSON-RPC, no agent card
  contents, no method names, ever touch the relay in the clear;
- **no public discovery surface** — the agent card is fetched in-band, after
  pairing, never published at a well-known URL.

This is a genuine A2A binding, not a bespoke protocol: every JSON-RPC method,
request, and response shape from the core specification is preserved unchanged.
Only the *transport* — how a request/response line physically moves from one
peer to the other, how the peer is discovered, and how the connection is
authenticated — is replaced.

## 2. Declaring support

An agent that supports this binding advertises it in its `AgentCard` two ways.

### 2.1 As a capability extension

```json
{
  "capabilities": {
    "extensions": [
      {
        "uri": "https://eldr.app/ext/a2a-pqrc-e2ee/v1",
        "description": "A2A over PQRC: end-to-end-encrypted, serverless transport binding over the Nostr relay network.",
        "required": false
      }
    ]
  }
}
```

`required` **MUST** be `false`: an agent that also exposes a standard binding
(HTTPS/JSON-RPC, gRPC, ...) does not require every caller to understand this
extension to use the agent at all — it requires it only to use *this specific
transport*.

### 2.2 As a supported interface

The binding itself is declared as an entry in `AgentCard.supportedInterfaces`,
using the extension URI as the `protocolBinding` value:

```json
{
  "supportedInterfaces": [
    {
      "url": "pqrc:a1b2c3d4e5f6...",
      "protocolBinding": "https://eldr.app/ext/a2a-pqrc-e2ee/v1",
      "protocolVersion": "1.0"
    }
  ]
}
```

- `url` is `pqrc:<peer-identifier>`, where `<peer-identifier>` is the responding
  agent's PQRC identity — the hex-encoded secp256k1 Nostr public key its
  kind-10420 identity-binding event is anchored to (§4). This is not a resolvable
  network address; it identifies *who to reach*, not *where*, since PQRC has no
  concept of a network location — the relay mesh is the transport.
- `protocolBinding` is `https://eldr.app/ext/a2a-pqrc-e2ee/v1` — this extension's
  URI, reused as the binding identifier. Per the A2A specification's
  `AgentInterface` object, `protocolBinding` is deliberately an **open string**:
  the core values (`JSONRPC`, `GRPC`, `HTTP+JSON`) are not an exhaustive enum, and
  extensions are the specified mechanism for declaring additional bindings. A
  client that does not understand this extension MUST skip this interface entry
  and fall back to another one the card offers (or fail, if none is usable) —
  exactly the behavior the open-string design exists to enable.
- `protocolVersion` is the A2A protocol version this interface speaks — `"1.0"`.

A card MAY list this interface alongside standard ones (e.g. an agent reachable
both over HTTPS and over PQRC to different callers); a client picks the
interface whose binding it understands, per the core specification's interface
selection guidance.

## 3. Transport mapping

Each A2A JSON-RPC 2.0 request, response, or notification is serialized to a
single UTF-8 line (standard `JSONRPCRequest`/`JSONRPCResponse` canonical JSON,
newline-free) exactly as the JSON-RPC/HTTP binding would serialize the request
body — nothing about the JSON-RPC envelope itself changes.

That line is then tunneled through the PQRC relay mesh as one or more relay
messages, using the same framing convention PQRC already uses for its other
line-oriented sub-protocols (its agent-control channel and its MCP tool-serving
channel), so all three can share one relay-message stream without cross-routing:

```text
A2A1|<lineId>|<seq>|<total>|<payloadB64Url>
```

Pipe-delimited, five fields:

- **`A2A1|`** — fixed magic prefix. A JSON-RPC line always begins with `{`, never
  with `A2A1|`, so a receiver can distinguish an A2A frame from ordinary PQRC
  chat, and from this profile's sibling sub-protocols, by an unambiguous prefix
  test (`ACP1|` and `MCP1|` are Eldr's separate agent-control and tool-serving
  channels over the same mesh; they differ from `A2A1|` in the first byte).
- **`lineId`** — `<random-instance-salt>-<base36 counter>`, identifying which
  original line a chunk belongs to and that line's position in send order.
- **`seq`** — 1-based chunk index.
- **`total`** — total chunk count for this line.
- **`payloadB64Url`** — base64url (RFC 4648 §5, unpadded) of this chunk's raw
  UTF-8 bytes.

A relay imposes a per-event byte budget (its NIP-11 `max_content_length`, minus
gift-wrap overhead); a JSON-RPC line that would exceed it is split so every
framed chunk fits, and reassembled on arrival keyed by `lineId` — tolerant of
the relay's out-of-order, at-least-once delivery. The receiving side further
restores **sender order** across separate lines (not just chunks within one
line): a relay delivers each line as an independently gift-wrapped event, so two
complete lines can surface in either order, and this binding's streaming model
(§7) depends on a notification reaching the peer before the final response that
follows it. See `Packages/PQRCNostr/Sources/PQRCNostr/RelayA2ATransport.swift`
for the reference implementation and `RelayFraming.swift` for the chunking/
reassembly core it shares with the sibling channels.

The relay never sees anything but this ciphertext-carrying envelope — the
`A2A1|...` frame itself is the *plaintext inside* an already gift-wrapped,
ratchet-encrypted PQRC message; what the relay stores and forwards is one more
layer of AEAD ciphertext indistinguishable from ordinary chat traffic (§5).

## 4. Discovery

This binding has **no `/.well-known/agent-card.json`** and no other public
discovery surface. Discovery is two-phase:

1. **Pairing (out of scope for this document; see PQRC SPEC §3.3).** Two PQRC
   peers exchange and mutually verify a **kind-10420 identity-binding event**,
   which cryptographically binds a Nostr signing key, a long-term identity key,
   and (where applicable) an agent key. Verification is bidirectional: each side
   confirms the *other's* binding before either trusts it. Only after this step
   do the peers share the relay-routable identifiers needed to exchange PQRC
   messages of any kind, A2A included.
2. **In-band card exchange.** Once paired, a peer requests the other's
   `AgentCard` with a profile-defined JSON-RPC method:

   - **Method:** `agent/getAgentCard`
   - **Params:** `{}`
   - **Result:** `AgentCard`

   This is analogous to the core specification's `GetExtendedAgentCard` method,
   but replaces well-known-URL fetch for the *base* card, since no well-known URL
   exists under this binding.

An implementation of this profile **MUST NOT** serve an `AgentCard` — in
response to `agent/getAgentCard` or otherwise — to a peer whose kind-10420
binding has not been verified. A peer that has not completed pairing has no way
to reach the agent over this transport at all (there is no listening socket to
connect to), but the requirement is stated explicitly because a future relay- or
gateway-mediated deployment could otherwise be tempted to serve the card
pre-pairing as a discovery convenience — doing so reintroduces exactly the
public-metadata exposure §1 exists to avoid.

## 5. Identity and authentication

`AgentCard.securitySchemes` **MUST** be empty (`{}`) for interfaces using this
binding. There is no OAuth flow, no API key, no bearer token, no HTTP auth
scheme layered on top — **authentication *is* the PQRC transport layer**, not a
scheme negotiated within A2A.

Concretely: the kind-10420 event exchanged during pairing (§4) cryptographically
binds the peer's Nostr signing key, its long-term identity key, and its agent
key (where the peer is an agent rather than a human-operated node), and this
binding is verified in **both directions** before any traffic — A2A or
otherwise — is accepted. Every A2A frame that reaches the JSON-RPC layer has
therefore already been:

- decrypted with a session key derived from a mutually authenticated key
  exchange (PQXDH — the Signal-style post-quantum X3DH pattern), and
- delivered inside a Double Ratchet session tied to that verified identity.

There is no separate "is this caller allowed to call this method" check at the
A2A layer beyond what the agent's own task/skill authorization logic imposes;
the question this binding answers is "is this caller who they claim to be,"
and it is answered before a single JSON-RPC byte is parsed.

The core specification's notion of an "authenticated user" (the principal
`SecurityScheme` verification would normally establish) maps, under this
binding, to **the verified PQRC ratchet peer** — identified by the Nostr public
key its kind-10420 binding is anchored to, the same identifier used in
`supportedInterfaces[].url` (§2.2).

## 6. Security considerations

The core specification requires HTTPS for its standard bindings. This binding
does not use HTTPS at all; instead every A2A frame is encrypted end-to-end by
the PQRC session before it reaches the relay. This section states precisely
what that buys, and what it does not, relative to a standard TLS-terminated
HTTPS binding.

### 6.1 Properties provided

- **Confidentiality.** Every frame is AEAD-encrypted under a Double Ratchet
  message key, itself wrapped in a NIP-59-style gift wrap (an inner signed
  "seal" and an outer envelope signed by a fresh, single-use key per message).
  The relay operator, and anyone observing relay traffic, sees only the outer
  gift-wrap ciphertext — no method names, no parameters, no agent card contents,
  no task IDs.
- **Integrity / authenticity.** AEAD provides per-message integrity; the seal is
  signed by the sender's Nostr identity key, so a forged or tampered frame is
  rejected before it reaches the JSON-RPC layer. There is no equivalent of a
  TLS-terminating middlebox that can observe or modify traffic un-detected.
- **Forward secrecy.** The Double Ratchet advances a symmetric-key chain on
  every message exchanged; a compromise of the current chain key does not
  expose previously ratcheted-past messages. Message keys are used once and
  deleted immediately after use.
- **Post-compromise security.** Each Diffie-Hellman ratchet step (and the
  periodic ML-KEM rekey, next) re-injects fresh entropy into the root key, so a
  session recovers confidentiality against a *future* adversary even after a
  transient compromise of ratchet state.
- **Post-quantum resistance.** The initial session key comes from a hybrid
  PQXDH handshake (X25519 + ML-KEM-768); breaking it requires breaking *both*
  primitives. Additionally, every `PQ_REKEY_INTERVAL` (50) messages, a fresh
  ML-KEM-768 encapsulation re-injects a post-quantum shared secret into the
  ratchet's root key (the same pattern as Apple's PQ3), bounding exposure to
  harvest-now-decrypt-later attacks against the *session*, not just its
  handshake.

### 6.2 Where this differs from TLS — honestly

- **No CA / PKI trust model.** There is no certificate authority validating
  "this is really `agent.example.com`." Trust is established directly,
  peer-to-peer, by the kind-10420 binding exchanged and verified during pairing
  (§4, §5) — closer to a key-continuity / TOFU model than to the web PKI. An
  implementation that skips or weakens the bidirectional verification step has
  no security here at all; this binding's entire authentication story rests on
  that step being done correctly.
- **No server.** There is nothing to compromise at a network layer that TLS
  would otherwise protect (no listening port, no certificate to steal, no
  server-side session to hijack) — but correspondingly there is no server-side
  operator providing uptime, abuse mitigation, or a point of accountability
  independent of the peers themselves.
- **No anonymity between the two peers, by design.** TLS client certificates are
  optional; a caller can often reach an HTTPS A2A endpoint without revealing who
  it is beyond its IP. This binding is the opposite: pairing *requires* each
  side to learn and verify the other's long-term identity key before any
  traffic flows. This binding does not attempt sender/recipient anonymity
  between the two paired peers — it protects the content of their exchange from
  everyone else (including the relay), not their knowledge of each other.
  Implementers who need that stronger property should look to PQRC's discussion
  of relay-visible metadata (recipient tag, approximate timing) in its own
  threat model; this binding inherits those properties unchanged.

## 7. Streaming methods

JSON-RPC 2.0 forbids more than one response per request `id`. The core A2A
specification's streaming methods (`SendStreamingMessage`, `SubscribeToTask`)
therefore rely, in the standard HTTP binding, on Server-Sent Events — a
transport-level mechanism outside JSON-RPC itself for delivering a *sequence*
of `StreamResponse` payloads before the logical request completes.

This binding has no SSE equivalent (there is no HTTP response stream to hold
open), so streaming is expressed as JSON-RPC **notifications**, profile-defined
by this specification:

- **Method:** `a2a/streamEvent`
- **Params:**
  ```json
  { "requestId": <original request id>, "event": <StreamResponse object> }
  ```
  `requestId` echoes the `id` of the `SendStreamingMessage`/`SubscribeToTask`
  request this event belongs to (a peer may have more than one streaming
  request in flight); `event` is exactly the `StreamResponse` oneof the core
  specification already defines (`task`, `message`, `statusUpdate`, or
  `artifactUpdate`).

Every non-terminal `StreamResponse` the agent generates for a request is sent
as one `a2a/streamEvent` notification, **in generation order** (guaranteed by
this binding's sender-order restoration, §3). The **terminal** `StreamResponse`
— the one that would have closed the SSE stream in the standard binding — is
**not** sent as a notification. Instead it is delivered as the payload of
**exactly one final, ordinary JSON-RPC response** to the original request `id`
(or, on failure, a JSON-RPC error response in its place). This keeps the
binding's use of JSON-RPC entirely conformant: exactly one response per
request, with every event that preceded it delivered as a distinct, ordered
notification.

### 7.1 Worked example

A caller sends a streaming message (request `id: 42`); the agent emits a
"working" status update, a two-part streamed text artifact, and finally a
"completed" status update that closes the request.

**Request:**

```json
{
  "jsonrpc": "2.0",
  "id": 42,
  "method": "SendStreamingMessage",
  "params": {
    "message": {
      "role": "ROLE_USER",
      "parts": [{ "kind": "text", "text": "Summarize this quarter's incidents." }]
    }
  }
}
```

**Notification 1 — status update (working):**

```json
{
  "jsonrpc": "2.0",
  "method": "a2a/streamEvent",
  "params": {
    "requestId": 42,
    "event": {
      "statusUpdate": {
        "taskId": "43667960-d455-4453-b0cf-1bae4955270d",
        "contextId": "c295ea44-7543-4f78-b524-7a38915ad6e4",
        "status": { "state": "TASK_STATE_WORKING", "timestamp": "2026-07-15T18:29:40Z" }
      }
    }
  }
}
```

**Notification 2 — first artifact chunk:**

```json
{
  "jsonrpc": "2.0",
  "method": "a2a/streamEvent",
  "params": {
    "requestId": 42,
    "event": {
      "artifactUpdate": {
        "taskId": "43667960-d455-4453-b0cf-1bae4955270d",
        "contextId": "c295ea44-7543-4f78-b524-7a38915ad6e4",
        "artifact": {
          "artifactId": "summary-1",
          "parts": [{ "kind": "text", "text": "Three incidents this quarter, all Sev-3. " }]
        },
        "append": false,
        "lastChunk": false
      }
    }
  }
}
```

**Notification 3 — final artifact chunk:**

```json
{
  "jsonrpc": "2.0",
  "method": "a2a/streamEvent",
  "params": {
    "requestId": 42,
    "event": {
      "artifactUpdate": {
        "taskId": "43667960-d455-4453-b0cf-1bae4955270d",
        "contextId": "c295ea44-7543-4f78-b524-7a38915ad6e4",
        "artifact": {
          "artifactId": "summary-1",
          "parts": [{ "kind": "text", "text": "No customer-facing downtime." }]
        },
        "append": true,
        "lastChunk": true
      }
    }
  }
}
```

**Final response — the terminal status update, as the request's one and only response:**

```json
{
  "jsonrpc": "2.0",
  "id": 42,
  "result": {
    "statusUpdate": {
      "taskId": "43667960-d455-4453-b0cf-1bae4955270d",
      "contextId": "c295ea44-7543-4f78-b524-7a38915ad6e4",
      "status": { "state": "TASK_STATE_COMPLETED", "timestamp": "2026-07-15T18:29:41Z" }
    }
  }
}
```

Each of these four JSON-RPC lines is independently framed and (if needed)
chunked per §3 and delivered as its own PQRC relay message; the receiving
`RelayA2ATransport` restores their generation order before handing lines up to
the JSON-RPC layer, so a consumer observes exactly this sequence regardless of
the relay's own delivery order.

## 8. Version negotiation

The standard bindings negotiate the A2A protocol version via an HTTP header
(`A2A-Version`) or an equivalent RPC-service parameter. This binding has no
HTTP headers, so version negotiation is carried in JSON-RPC `params` instead:

- The requester **MUST** include `"a2aVersion": "1.0"` as a top-level member of
  the `params` object of every `agent/getAgentCard` request (§4).
- Every other request's `params` object **MAY** carry `"a2aVersion"`.
- **Absence** of `a2aVersion` on any request means **`"1.0"`** under this
  binding — *not* the core specification's general default of `"0.3"`. This
  profile postdates the 0.3 wire format and does not implement it; there is no
  ambiguity to resolve because no 0.3 peer can attempt this transport.
- A request naming an `a2aVersion` this responder does not support **MUST**
  receive a JSON-RPC error response with code **`-32009`**
  (`VersionNotSupportedError`), per the core specification's error table.

## 9. Push notifications

This binding has no notion of a webhook: there is no outbound HTTPS call the
agent could make to "push" to, and requiring one would reintroduce exactly the
address-exposure problem (§1) this profile exists to avoid — the caller would
have to hand the agent a reachable URL of its own.

- Every `*TaskPushNotificationConfig` method (`CreateTaskPushNotificationConfig`,
  `GetTaskPushNotificationConfig`, `ListTaskPushNotificationConfigs`,
  `DeleteTaskPushNotificationConfig`) **MUST** return a JSON-RPC error with code
  **`-32003`** (`PushNotificationNotSupportedError`) under this binding.
- This is not a capability loss in practice: the PQRC tunnel this binding rides
  on is **inherently bidirectional** — either peer can send at any time, the
  connection is not request/response-shaped at the transport level the way HTTP
  is. `SubscribeToTask` (§7) already delivers exactly what a push notification
  would have: asynchronous task updates, delivered as they occur, without
  either side needing to expose an inbound endpoint.

## 10. Consent (informative)

This section is informative, not part of the normative binding: the core A2A
specification does not mandate a consent step, and nothing above requires one.
It is included because an implementation that skips it defeats much of the
point of a *personal*-agent transport.

Because this binding removes the network-topology friction that (incidentally)
limits who can reach an HTTPS A2A endpoint, implementations of a personal-agent
peer **SHOULD** gate inbound tasks behind **explicit, per-task human approval**
before the agent acts on them — a paired peer is a peer whose *identity* is
verified (§5), not necessarily a peer whose every request should execute
unattended.

Eldr's implementation parks an inbound task at `TASK_STATE_SUBMITTED` on
arrival and does not advance it until the device owner explicitly approves it;
denial, or a timeout with no response, resolves the task to
`TASK_STATE_REJECTED`. This is a policy choice layered on top of the binding,
not a protocol requirement — other implementations MAY choose a different
consent model (e.g. skill-scoped pre-approval) without breaking
interoperability, since the wire behavior (task states, error codes) is
unchanged either way.

## 11. Conformance summary

An implementation of this binding:

- **MUST** frame every JSON-RPC line as `A2A1|<lineId>|<seq>|<total>|<payloadB64Url>`
  and chunk to the relay's advertised `max_content_length` (§3).
- **MUST NOT** publish an `AgentCard` at any public well-known URL; **MUST**
  serve it only via `agent/getAgentCard`, and only to peers whose kind-10420
  binding has been verified bidirectionally (§4).
- **MUST** declare `securitySchemes: {}` for interfaces using this binding (§5).
- **MUST** implement streaming via `a2a/streamEvent` notifications plus exactly
  one terminal JSON-RPC response, never multiple JSON-RPC responses to one
  request id (§7).
- **MUST** honor `a2aVersion` negotiation as specified, defaulting absence to
  `"1.0"` (§8), returning `-32009` for an unsupported version.
- **MUST** return `-32003` for every push-notification-config method (§9).
- **SHOULD** gate inbound tasks behind explicit human approval (§10).

## 12. References

- A2A specification (core): `AgentCard`, `AgentInterface`, `SecurityScheme`,
  JSON-RPC transport binding, streaming methods, error codes.
- RFC 2119 / RFC 8174 — key words for use in RFCs.
- RFC 4648 §5 — base64url encoding.
- PQRC SPEC v1.1 — `docs/pqrc-SPEC-v1_1.md` (this repository): §3.3 (kind-10420
  bidirectional binding verification), §4–§6 (PQXDH handshake, Double Ratchet,
  periodic ML-KEM rekey), §8 (gift wrap).
- NIP-XX (pqrc) — `docs/NIP-XX-pqrc.md` (this repository): wire format for the
  identity-binding event, seal, and gift wrap this binding's authentication
  rests on.
- Reference implementation — `Packages/PQRCNostr/Sources/PQRCNostr/RelayA2ATransport.swift`
  (transport/framing) and `Packages/SwiftA2A` (A2A core types, JSON-RPC, and the
  standard HTTP binding this profile is a sibling to).
