// SPDX-License-Identifier: Apache-2.0
import Testing

@testable import A2ACore
@testable import A2AServer

@Suite struct VersionGateTests {
    @Test func absentVersionIsRejected() async throws {
        let server = A2AServer(card: Fixtures.card(), executor: ScriptedExecutor())
        let line = try Fixtures.line(method: .getTask, params: A2AGetTaskRequest(id: "x"))
        let response = try Fixtures.decodeSingle(
            await server.handle(rpcLine: line, context: Fixtures.context(version: nil)))
        #expect(response.error?.code == .versionNotSupported)
        #expect(response.id == nil)  // version gate runs before the body is even parsed
    }

    @Test func zeroDotThreeIsRejected() async throws {
        let server = A2AServer(card: Fixtures.card(), executor: ScriptedExecutor())
        let line = try Fixtures.line(method: .getTask, params: A2AGetTaskRequest(id: "x"))
        let response = try Fixtures.decodeSingle(
            await server.handle(rpcLine: line, context: Fixtures.context(version: "0.3")))
        #expect(response.error?.code == .versionNotSupported)
    }

    @Test func twoDotZeroIsRejected() async throws {
        let server = A2AServer(card: Fixtures.card(), executor: ScriptedExecutor())
        let line = try Fixtures.line(method: .getTask, params: A2AGetTaskRequest(id: "x"))
        let response = try Fixtures.decodeSingle(
            await server.handle(rpcLine: line, context: Fixtures.context(version: "2.0")))
        #expect(response.error?.code == .versionNotSupported)
    }

    @Test func oneDotZeroPasses() async throws {
        let server = A2AServer(card: Fixtures.card(), executor: ScriptedExecutor())
        let line = try Fixtures.line(method: .getTask, params: A2AGetTaskRequest(id: "missing"))
        let response = try Fixtures.decodeSingle(
            await server.handle(rpcLine: line, context: Fixtures.context(version: "1.0")))
        // Past the version gate, into real dispatch: taskNotFound, not versionNotSupported.
        #expect(response.error?.code == .taskNotFound)
    }
}

@Suite struct ParseFailureTests {
    @Test func malformedJSONIsAJSONParseError() async throws {
        let server = A2AServer(card: Fixtures.card(), executor: ScriptedExecutor())
        let response = try Fixtures.decodeSingle(
            await server.handle(rpcLine: "{not json", context: Fixtures.context()))
        #expect(response.error?.code == .jsonParseError)
        #expect(response.id == nil)
    }

    @Test func validJSONInvalidEnvelopeIsInvalidRequest() async throws {
        let server = A2AServer(card: Fixtures.card(), executor: ScriptedExecutor())
        // Valid JSON, but not a JSON-RPC 2.0 request (wrong jsonrpc version).
        let response = try Fixtures.decodeSingle(
            await server.handle(
                rpcLine: #"{"jsonrpc":"1.0","id":1,"method":"GetTask"}"#,
                context: Fixtures.context()))
        #expect(response.error?.code == .invalidRequest)
        #expect(response.id == nil)
    }

    @Test func notificationWithoutIdGetsNoResponse() async throws {
        let server = A2AServer(card: Fixtures.card(), executor: ScriptedExecutor())
        let response = await server.handle(
            rpcLine: #"{"jsonrpc":"2.0","method":"GetTask","params":{"id":"x"}}"#,
            context: Fixtures.context())
        #expect(response == nil)
    }
}

@Suite struct SendMessageTests {
    @Test func happyPathReturnsCompletedTaskWithArtifacts() async throws {
        let executor = ScriptedExecutor()
        let server = A2AServer(card: Fixtures.card(), executor: executor)
        let line = try Fixtures.line(
            method: .sendMessage, params: A2ASendMessageRequest(message: Fixtures.message()))
        let response = try Fixtures.decodeSingle(
            await server.handle(rpcLine: line, context: Fixtures.context()))
        let result = try response.decodeResult(A2ASendMessageResponse.self)
        guard case .task(let task) = result else {
            Issue.record("expected .task result")
            return
        }
        #expect(task.status.state == .completed)
        #expect(task.artifacts.count == 1)  // second chunk appended onto the first
        #expect(task.artifacts[0].parts.compactMap(\.text) == ["chunk one", " chunk two"])
        #expect(task.history.count == 1)  // only the original inbound message
    }

    @Test func returnImmediatelyRespondsWithSubmittedTask() async throws {
        let executor = ScriptedExecutor()
        await executor.configure(waitForCancel: true)  // never lets execute() finish
        let server = A2AServer(card: Fixtures.card(), executor: executor)
        let params = A2ASendMessageRequest(
            message: Fixtures.message(),
            configuration: A2ASendMessageConfiguration(returnImmediately: true))
        let line = try Fixtures.line(method: .sendMessage, params: params)
        let response = try Fixtures.decodeSingle(
            await server.handle(rpcLine: line, context: Fixtures.context()))
        let result = try response.decodeResult(A2ASendMessageResponse.self)
        guard case .task(let task) = result else {
            Issue.record("expected .task result")
            return
        }
        #expect(task.status.state == .submitted)
    }

    @Test func emptyPartsIsInvalidParams() async throws {
        let server = A2AServer(card: Fixtures.card(), executor: ScriptedExecutor())
        let params = A2ASendMessageRequest(message: A2AMessage(role: .user, parts: []))
        let line = try Fixtures.line(method: .sendMessage, params: params)
        let response = try Fixtures.decodeSingle(
            await server.handle(rpcLine: line, context: Fixtures.context()))
        #expect(response.error?.code == .invalidParams)
    }

    @Test func throwingExecutorProducesFailedWithLocalizedMessage() async throws {
        let server = A2AServer(card: Fixtures.card(), executor: ThrowingExecutor())
        let line = try Fixtures.line(
            method: .sendMessage, params: A2ASendMessageRequest(message: Fixtures.message()))
        let response = try Fixtures.decodeSingle(
            await server.handle(rpcLine: line, context: Fixtures.context()))
        let result = try response.decodeResult(A2ASendMessageResponse.self)
        guard case .task(let task) = result else {
            Issue.record("expected .task result")
            return
        }
        #expect(task.status.state == .failed)
        #expect(task.status.message?.parts.first?.text == "boom")
        #expect(task.history.last?.parts.first?.text == "boom")
    }
}

@Suite struct GetTaskCancelTaskTests {
    @Test func getMissingTaskIsTaskNotFound() async throws {
        let server = A2AServer(card: Fixtures.card(), executor: ScriptedExecutor())
        let line = try Fixtures.line(method: .getTask, params: A2AGetTaskRequest(id: "nope"))
        let response = try Fixtures.decodeSingle(
            await server.handle(rpcLine: line, context: Fixtures.context()))
        #expect(response.error?.code == .taskNotFound)
    }

    @Test func cancelMissingTaskIsTaskNotFound() async throws {
        let server = A2AServer(card: Fixtures.card(), executor: ScriptedExecutor())
        let line = try Fixtures.line(method: .cancelTask, params: A2ACancelTaskRequest(id: "nope"))
        let response = try Fixtures.decodeSingle(
            await server.handle(rpcLine: line, context: Fixtures.context()))
        #expect(response.error?.code == .taskNotFound)
    }

    @Test func cancelTerminalTaskIsTaskNotCancelable() async throws {
        let executor = ScriptedExecutor()
        let server = A2AServer(card: Fixtures.card(), executor: executor)
        let sendLine = try Fixtures.line(
            method: .sendMessage, params: A2ASendMessageRequest(message: Fixtures.message()))
        let sendResponse = try Fixtures.decodeSingle(
            await server.handle(rpcLine: sendLine, context: Fixtures.context()))
        let sent = try sendResponse.decodeResult(A2ASendMessageResponse.self)
        guard case .task(let task) = sent else {
            Issue.record("expected .task result")
            return
        }
        #expect(task.status.state == .completed)  // already terminal

        let cancelLine = try Fixtures.line(
            method: .cancelTask, params: A2ACancelTaskRequest(id: task.id))
        let cancelResponse = try Fixtures.decodeSingle(
            await server.handle(rpcLine: cancelLine, context: Fixtures.context()))
        #expect(cancelResponse.error?.code == .taskNotCancelable)
    }

    @Test func cancelMidExecutionTransitionsToCanceledAndCallsExecutorCancel() async throws {
        let executor = ScriptedExecutor()
        await executor.configure(waitForCancel: true)
        let store = InMemoryTaskStore()
        let server = A2AServer(card: Fixtures.card(), executor: executor, taskStore: store)

        let sendLine = try Fixtures.line(
            method: .sendMessage, params: A2ASendMessageRequest(message: Fixtures.message()))
        async let sendResult: A2AServer.Response? = server.handle(
            rpcLine: sendLine, context: Fixtures.context())

        await executor.waitUntilBlockedOnCancel()

        let listed = await store.list(matching: A2AListTasksRequest())
        let taskId = try #require(listed.tasks.first?.id)
        #expect(listed.tasks.first?.status.state == .working)

        let cancelLine = try Fixtures.line(
            id: 2, method: .cancelTask, params: A2ACancelTaskRequest(id: taskId))
        let cancelResponse = try Fixtures.decodeSingle(
            await server.handle(rpcLine: cancelLine, context: Fixtures.context()))
        let canceledTask = try cancelResponse.decodeResult(A2ATask.self)
        #expect(canceledTask.status.state == .canceled)

        let finalSendResponse = try Fixtures.decodeSingle(await sendResult)
        let finalResult = try finalSendResponse.decodeResult(A2ASendMessageResponse.self)
        guard case .task(let finalTask) = finalResult else {
            Issue.record("expected .task result")
            return
        }
        #expect(finalTask.status.state == .canceled)

        let cancelCalls = await executor.cancelCalls
        #expect(cancelCalls == [taskId])
    }
}

@Suite struct ListTasksTests {
    @Test func listFiltersByContextAndStatusAndPaginates() async throws {
        let store = InMemoryTaskStore()
        let executor = ScriptedExecutor()
        let server = A2AServer(card: Fixtures.card(), executor: executor, taskStore: store)

        let sharedContext = "ctx-shared"
        for i in 0..<2 {
            var message = Fixtures.message(text: "msg \(i)")
            message.contextId = sharedContext
            let line = try Fixtures.line(
                id: i, method: .sendMessage, params: A2ASendMessageRequest(message: message))
            _ = try Fixtures.decodeSingle(
                await server.handle(rpcLine: line, context: Fixtures.context()))
        }
        // A third task in an unrelated context, which the filter below must exclude.
        let otherLine = try Fixtures.line(
            id: 99, method: .sendMessage,
            params: A2ASendMessageRequest(message: Fixtures.message(text: "other")))
        _ = try Fixtures.decodeSingle(
            await server.handle(rpcLine: otherLine, context: Fixtures.context()))

        let listLine = try Fixtures.line(
            id: 100, method: .listTasks,
            params: A2AListTasksRequest(
                contextId: sharedContext, status: .completed, pageSize: 1))
        let listResponse = try Fixtures.decodeSingle(
            await server.handle(rpcLine: listLine, context: Fixtures.context()))
        let listed = try listResponse.decodeResult(A2AListTasksResponse.self)
        #expect(listed.totalSize == 2)  // only the shared-context tasks
        #expect(listed.tasks.count == 1)  // pageSize 1
        #expect(!listed.nextPageToken.isEmpty)
    }
}

@Suite struct StreamingTests {
    @Test func sendStreamingMessageEmitsExpectedFrameSequence() async throws {
        let executor = ScriptedExecutor()
        let server = A2AServer(card: Fixtures.card(), executor: executor)
        let line = try Fixtures.line(
            method: .sendStreamingMessage,
            params: A2ASendMessageRequest(message: Fixtures.message()))
        let stream = try Fixtures.decodeStream(
            await server.handle(rpcLine: line, context: Fixtures.context()))
        let frames = try await Fixtures.collectStreamResponses(stream)

        #expect(frames.count == 5)
        guard case .task(let submitted) = frames[0] else {
            Issue.record("frame 0 should be .task"); return
        }
        #expect(submitted.status.state == .submitted)

        guard case .statusUpdate(let working) = frames[1] else {
            Issue.record("frame 1 should be statusUpdate"); return
        }
        #expect(working.status.state == .working)

        guard case .artifactUpdate = frames[2] else {
            Issue.record("frame 2 should be artifactUpdate"); return
        }
        guard case .artifactUpdate = frames[3] else {
            Issue.record("frame 3 should be artifactUpdate"); return
        }

        guard case .statusUpdate(let final) = frames[4] else {
            Issue.record("frame 4 should be statusUpdate"); return
        }
        #expect(final.status.state == .completed)
    }

    @Test func subscribeToTerminalTaskIsUnsupportedOperation() async throws {
        let executor = ScriptedExecutor()
        let server = A2AServer(card: Fixtures.card(), executor: executor)
        let sendLine = try Fixtures.line(
            method: .sendMessage, params: A2ASendMessageRequest(message: Fixtures.message()))
        let sendResponse = try Fixtures.decodeSingle(
            await server.handle(rpcLine: sendLine, context: Fixtures.context()))
        let sent = try sendResponse.decodeResult(A2ASendMessageResponse.self)
        guard case .task(let task) = sent else {
            Issue.record("expected .task result"); return
        }
        #expect(task.status.state == .completed)

        let subLine = try Fixtures.line(
            id: 2, method: .subscribeToTask, params: A2ASubscribeToTaskRequest(id: task.id))
        let subResponse = try Fixtures.decodeSingle(
            await server.handle(rpcLine: subLine, context: Fixtures.context()))
        #expect(subResponse.error?.code == .unsupportedOperation)
    }

    @Test func subscribeToMissingTaskIsTaskNotFound() async throws {
        let server = A2AServer(card: Fixtures.card(), executor: ScriptedExecutor())
        let line = try Fixtures.line(
            method: .subscribeToTask, params: A2ASubscribeToTaskRequest(id: "nope"))
        let response = try Fixtures.decodeSingle(
            await server.handle(rpcLine: line, context: Fixtures.context()))
        #expect(response.error?.code == .taskNotFound)
    }

    @Test func twoConcurrentSubscribersReceiveAllEventsInOrder() async throws {
        let executor = ScriptedExecutor()
        await executor.configure(blockAtStart: true)
        let store = InMemoryTaskStore()
        let server = A2AServer(card: Fixtures.card(), executor: executor, taskStore: store)

        // Create the task with the executor parked before it emits anything, so
        // subscribing afterward cannot race any event.
        let sendParams = A2ASendMessageRequest(
            message: Fixtures.message(),
            configuration: A2ASendMessageConfiguration(returnImmediately: true))
        let sendLine = try Fixtures.line(method: .sendMessage, params: sendParams)
        let sendResponse = try Fixtures.decodeSingle(
            await server.handle(rpcLine: sendLine, context: Fixtures.context()))
        let sent = try sendResponse.decodeResult(A2ASendMessageResponse.self)
        guard case .task(let task) = sent else {
            Issue.record("expected .task result"); return
        }

        // Deterministic sync point: by the time this returns, `A2AServer`'s own
        // automatic SUBMITTED->WORKING transition (fired before `execute` was even
        // called) has already happened and, having had no subscribers yet, was
        // necessarily missed. Subscribing only after this point means both
        // subscribers start from the same clean slate regardless of scheduling.
        await executor.waitUntilBlockedAtStart()

        let sub1Line = try Fixtures.line(
            id: 2, method: .subscribeToTask, params: A2ASubscribeToTaskRequest(id: task.id))
        let sub2Line = try Fixtures.line(
            id: 3, method: .subscribeToTask, params: A2ASubscribeToTaskRequest(id: task.id))
        let stream1 = try Fixtures.decodeStream(
            await server.handle(rpcLine: sub1Line, context: Fixtures.context()))
        let stream2 = try Fixtures.decodeStream(
            await server.handle(rpcLine: sub2Line, context: Fixtures.context()))

        async let frames1 = Fixtures.collectStreamResponses(stream1)
        async let frames2 = Fixtures.collectStreamResponses(stream2)

        await executor.proceed()

        let events1 = try await frames1
        let events2 = try await frames2

        #expect(events1.count == 3)  // artifact, artifact, COMPLETED
        #expect(events1 == events2)
    }
}

@Suite struct PushNotificationAndExtendedCardTests {
    @Test func allFourPushNotificationConfigMethodsAreUnsupported() async throws {
        let server = A2AServer(card: Fixtures.card(), executor: ScriptedExecutor())
        let methods: [A2AMethod] = [
            .createTaskPushNotificationConfig, .getTaskPushNotificationConfig,
            .listTaskPushNotificationConfigs, .deleteTaskPushNotificationConfig,
        ]
        for method in methods {
            let line = try Fixtures.rawLine(method: method)
            let response = try Fixtures.decodeSingle(
                await server.handle(rpcLine: line, context: Fixtures.context()))
            #expect(
                response.error?.code == .pushNotificationNotSupported,
                "\(method.rawValue) should be pushNotificationNotSupported")
        }
    }

    @Test func getExtendedAgentCardIsUnsupportedByDefault() async throws {
        let server = A2AServer(card: Fixtures.card(), executor: ScriptedExecutor())
        let line = try Fixtures.rawLine(method: .getExtendedAgentCard)
        let response = try Fixtures.decodeSingle(
            await server.handle(rpcLine: line, context: Fixtures.context()))
        #expect(response.error?.code == .unsupportedOperation)
    }

    @Test func getExtendedAgentCardServesCardWhenCapabilityIsTrue() async throws {
        let server = A2AServer(
            card: Fixtures.card(extendedAgentCard: true), executor: ScriptedExecutor())
        let line = try Fixtures.rawLine(method: .getExtendedAgentCard)
        let response = try Fixtures.decodeSingle(
            await server.handle(rpcLine: line, context: Fixtures.context()))
        let card = try response.decodeResult(A2AAgentCard.self)
        #expect(card.name == "Test Agent")
    }

    @Test func unknownMethodIsMethodNotFound() async throws {
        let server = A2AServer(card: Fixtures.card(), executor: ScriptedExecutor())
        let request = JSONRPCRequest(id: .int(1), method: "TotallyMadeUpMethod", params: nil)
        let line = try A2AWireCodec.encodeString(request)
        let response = try Fixtures.decodeSingle(
            await server.handle(rpcLine: line, context: Fixtures.context()))
        #expect(response.error?.code == .methodNotFound)
    }
}
