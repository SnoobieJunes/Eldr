// SPDX-License-Identifier: Apache-2.0
#if os(Linux)
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket
import Testing

@testable import PQRCNostr

// WS-L5 — proves NIOWebSocketChannel actually connects and exchanges frames on Linux, where
// URLSessionWebSocketTask is non-functional ("WebSockets not supported by libcurl"). A NIO
// WebSocket echo server over loopback (ws://); the TLS layer (NIOSSL) rides in front unchanged
// and is validated live against the real wss:// relay on-device.

private final class WSEchoServerHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        switch frame.opcode {
        case .text:
            // Server→client frames are unmasked (RFC 6455).
            let echo = WebSocketFrame(
                fin: true, opcode: .text, maskKey: nil, data: frame.unmaskedData)
            context.writeAndFlush(wrapOutboundOut(echo), promise: nil)
        case .connectionClose:
            context.close(promise: nil)
        default:
            break
        }
    }
}

@Suite("WS-L5 NIO WebSocket on Linux")
struct NIOWebSocketChannelTests {
    @Test(.timeLimit(.minutes(1)))
    func connectsAndEchoesOverLoopback() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        let server = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                let upgrader = NIOWebSocketServerUpgrader(
                    maxFrameSize: 1 << 20,
                    shouldUpgrade: { channel, _ in
                        channel.eventLoop.makeSucceededFuture(HTTPHeaders())
                    },
                    upgradePipelineHandler: { channel, _ in
                        channel.pipeline.addHandler(WSEchoServerHandler())
                    })
                let config: NIOHTTPServerUpgradeConfiguration = (
                    upgraders: [upgrader], completionHandler: { _ in })
                return channel.pipeline.configureHTTPServerPipeline(withServerUpgrade: config)
            }
            .bind(host: "127.0.0.1", port: 0).get()

        let port = try #require(server.localAddress?.port)

        let client = NIOWebSocketChannel(group: group)
        try await client.connect(url: #require(URL(string: "ws://127.0.0.1:\(port)")))
        var iterator = client.inboundText().makeAsyncIterator()
        try await client.send(text: "hello nostr over nio")
        let received = await iterator.next()
        #expect(received == "hello nostr over nio")
        // Regression (audit finding 1): a frame larger than the 16 KiB default must survive —
        // relay events (padded to buckets up to 64 KiB, gift-wrapped) routinely exceed it, and a
        // too-small maxFrameSize silently tore the socket down on the first real event.
        let big = String(repeating: "x", count: 20_000)
        try await client.send(text: big)
        let receivedBig = await iterator.next()
        #expect(receivedBig == big)
        await client.close()
        try? await group.shutdownGracefully()
    }
}
#endif
