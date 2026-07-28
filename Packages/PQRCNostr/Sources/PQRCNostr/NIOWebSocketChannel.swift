// SPDX-License-Identifier: Apache-2.0
#if os(Linux)
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import NIOWebSocket

// WS-L5 — the Linux WebSocket+TLS relay byte-channel. `URLSessionWebSocketTask` is unusable on
// swift-corelibs Foundation ("WebSockets not supported by libcurl"), so a Linux node dials the
// `wss://` relay over SwiftNIO instead. This is a thin byte-channel — connect / send text /
// an inbound text stream / close — over which NIP-01 framing rides via `NostrWire`, exactly as
// the URLSession path does on Apple. Client frames are masked per RFC 6455; ping is answered
// with a masked pong; a server close finishes the inbound stream.

public enum NIOWebSocketError: Error, Sendable { case badURL, notConnected, upgradeTimedOut }

// @unchecked Sendable JUSTIFICATION (CLAUDE.md requires a written one): the only mutable fields
// (`channel`, `pingTask`) are assigned exactly once inside `connect()` — which the owning
// `NIONostrTransport` actor calls before any `send`/`close` uses the instance — and are read-only
// thereafter (write-once). The inbound `AsyncStream.Continuation` is itself thread-safe (yield /
// finish are safe from any thread). No field is mutated concurrently, so the class presents a
// data-race-free interface across tasks.
public final class NIOWebSocketChannel: @unchecked Sendable {
    private let group: EventLoopGroup
    private let ownsGroup: Bool
    private var channel: Channel?
    private var pingTask: Task<Void, Never>?
    private let inbound: AsyncStream<String>
    private let inboundCont: AsyncStream<String>.Continuation

    public init(group: EventLoopGroup? = nil) {
        if let group {
            self.group = group
            self.ownsGroup = false
        } else {
            self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            self.ownsGroup = true
        }
        (inbound, inboundCont) = AsyncStream.makeStream(of: String.self)
    }

    /// Text frames received from the peer (NIP-01 relay messages). Finishes on close.
    public func inboundText() -> AsyncStream<String> { inbound }

    public func connect(url: URL) async throws {
        guard let host = url.host else { throw NIOWebSocketError.badURL }
        let isTLS = (url.scheme == "wss")
        let port = url.port ?? (isTLS ? 443 : 80)
        var uri = url.path.isEmpty ? "/" : url.path
        if let query = url.query, !query.isEmpty { uri += "?\(query)" }

        let cont = inboundCont
        let upgradePromise = group.next().makePromise(of: Void.self)

        var keyBytes = [UInt8](repeating: 0, count: 16)
        for index in keyBytes.indices { keyBytes[index] = UInt8.random(in: 0...255) }
        let requestKey = Data(keyBytes).base64EncodedString()

        let bootstrap = ClientBootstrap(group: group)
            .connectTimeout(.seconds(15))
            .channelInitializer { channel in
                let upgrader = NIOWebSocketClientUpgrader(
                    requestKey: requestKey,
                    // Relay events are padded to buckets up to 64 KiB and gift-wrapped, so they
                    // exceed the 16 KiB default frame size — a small default silently tears the
                    // socket down on the first real event. Cap at 1 MiB and aggregate fragments.
                    maxFrameSize: 1 << 20,
                    upgradePipelineHandler: { channel, _ in
                        channel.pipeline.addHandler(
                            NIOWebSocketFrameAggregator(
                                minNonFinalFragmentSize: 0,
                                maxAccumulatedFrameCount: 1 << 12,
                                maxAccumulatedFrameSize: 4 << 20)
                        ).flatMap {
                            channel.pipeline.addHandler(WSInboundHandler(continuation: cont))
                        }
                    })
                let upgradeConfig: NIOHTTPClientUpgradeConfiguration = (
                    upgraders: [upgrader],
                    completionHandler: { _ in upgradePromise.succeed(()) })

                func addHTTP() -> EventLoopFuture<Void> {
                    channel.pipeline.addHTTPClientHandlers(withClientUpgrade: upgradeConfig)
                }
                if isTLS {
                    do {
                        let sslContext = try NIOSSLContext(
                            configuration: TLSConfiguration.makeClientConfiguration())
                        let sslHandler = try NIOSSLClientHandler(
                            context: sslContext, serverHostname: host)
                        return channel.pipeline.addHandler(sslHandler).flatMap { addHTTP() }
                    } catch {
                        return channel.eventLoop.makeFailedFuture(error)
                    }
                }
                return addHTTP()
            }

        // A failed TCP connect (or a failed request write) must RESOLVE the upgrade promise —
        // otherwise it leaks (NIO asserts) and connect() would hang. `cascadeFailure` fires only
        // on failure, and the failure and upgrade-success paths are mutually exclusive (a failed
        // connect never upgrades), so the promise is always resolved exactly once.
        let connectFuture = bootstrap.connect(host: host, port: port)
        connectFuture.cascadeFailure(to: upgradePromise)
        let opened = try await connectFuture.get()
        self.channel = opened

        // Send the upgrade request; NIOWebSocketClientUpgrader appends the WS headers.
        var headers = HTTPHeaders()
        headers.add(name: "Host", value: "\(host):\(port)")
        headers.add(name: "Content-Length", value: "0")
        let requestHead = HTTPRequestHead(
            version: .http1_1, method: .GET, uri: uri, headers: headers)
        opened.write(HTTPClientRequestPart.head(requestHead), promise: nil)
        opened.writeAndFlush(HTTPClientRequestPart.end(nil)).cascadeFailure(to: upgradePromise)

        // Bound the upgrade wait: a well-formed non-101 response (a Cloudflare 4xx/5xx / challenge
        // page / redirect) takes swift-nio's "not upgrading" path, which resolves NOTHING — so
        // without a deadline the daemon hangs forever at startup. The deadline is scheduled ON THE
        // EVENT LOOP to FAIL the promise, NOT raced in a task group: `EventLoopFuture.get()` does
        // not observe Swift task cancellation (it is documented not to), so a task-group race can
        // never unblock the `get()` awaiting an unresolved promise — the group would hang at scope
        // exit and the timeout would be inert. Failing the promise instead makes `get()` throw
        // cleanly AND fulfills it, so it can't hit NIO's debug promise-leak precondition. `fail`
        // after a `succeed` is an idempotent no-op (whichever the upgrade/timeout race wins stands),
        // and completing the promise cancels the timer so it never lingers.
        let upgradeTimeout = opened.eventLoop.scheduleTask(in: .seconds(15)) {
            upgradePromise.fail(NIOWebSocketError.upgradeTimedOut)
        }
        upgradePromise.futureResult.whenComplete { _ in upgradeTimeout.cancel() }
        do {
            try await upgradePromise.futureResult.get()
        } catch {
            try? await opened.close().get()
            throw error
        }

        // Keep-alive: a masked ping every 30 s so an idle connection isn't dropped by an
        // intermediary (this relay sits behind Cloudflare, which closes idle WebSockets ~100 s).
        let pingChannel = opened
        pingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard pingChannel.isActive else { break }
                let ping = WebSocketFrame(
                    fin: true, opcode: .ping, maskKey: Self.randomMask(),
                    data: pingChannel.allocator.buffer(capacity: 0))
                _ = try? await pingChannel.writeAndFlush(ping).get()
            }
        }
    }

    public func send(text: String) async throws {
        guard let channel else { throw NIOWebSocketError.notConnected }
        var buffer = channel.allocator.buffer(capacity: text.utf8.count)
        buffer.writeString(text)
        let frame = WebSocketFrame(
            fin: true, opcode: .text, maskKey: Self.randomMask(), data: buffer)
        try await channel.writeAndFlush(frame).get()
    }

    public func close() async {
        pingTask?.cancel()
        try? await channel?.close().get()
        inboundCont.finish()
        if ownsGroup { try? await group.shutdownGracefully() }
    }

    static func randomMask() -> WebSocketMaskingKey {
        var bytes = [UInt8](repeating: 0, count: 4)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        // `WebSocketMaskingKey.init?` only returns nil for a non-4-byte input; `bytes` is
        // always exactly 4, so the nil branch is truly unreachable (RFC 6455 mask = 4 bytes).
        return WebSocketMaskingKey(bytes)!
    }
}

/// Turns inbound WebSocket frames into the channel's text stream; answers pings; finishes on
/// close. Runs on the NIO event loop (never touches the actor above).
private final class WSInboundHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let continuation: AsyncStream<String>.Continuation
    init(continuation: AsyncStream<String>.Continuation) { self.continuation = continuation }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        switch frame.opcode {
        case .text:
            continuation.yield(String(buffer: frame.unmaskedData))
        case .ping:
            let pong = WebSocketFrame(
                fin: true, opcode: .pong, maskKey: NIOWebSocketChannel.randomMask(),
                data: frame.unmaskedData)
            context.writeAndFlush(wrapOutboundOut(pong), promise: nil)
        case .connectionClose:
            continuation.finish()
            context.close(promise: nil)
        default:
            break
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        continuation.finish()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        continuation.finish()
        context.close(promise: nil)
    }
}
#endif
