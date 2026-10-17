import XCTest
import TaskProcessor

fileprivate enum StudentTestError: Error, Equatable {
    case boom
}

fileprivate actor StudentGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }
}

fileprivate actor StudentProbe {
    private(set) var started: [String] = []
    private(set) var finished: [String] = []
    private(set) var attempts: [String: [Int]] = [:]
    private(set) var active = 0
    private(set) var maxActive = 0

    private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var finishWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func begin(_ id: String) {
        started.append(id)
        active += 1
        maxActive = max(maxActive, active)
        let ready = startWaiters.filter { started.count >= $0.0 }
        startWaiters.removeAll { started.count >= $0.0 }
        for entry in ready { entry.1.resume() }
    }

    func end(_ id: String) {
        active -= 1
        finished.append(id)
        let ready = finishWaiters.filter { finished.count >= $0.0 }
        finishWaiters.removeAll { finished.count >= $0.0 }
        for entry in ready { entry.1.resume() }
    }

    func recordAttempt(_ attempt: Int, for id: String) {
        attempts[id, default: []].append(attempt)
    }

    func waitForStarted(_ count: Int) async {
        if started.count >= count { return }
        await withCheckedContinuation { startWaiters.append((count, $0)) }
    }

    func waitForFinished(_ count: Int) async {
        if finished.count >= count { return }
        await withCheckedContinuation { finishWaiters.append((count, $0)) }
    }
}

fileprivate func studentTracked(
    _ probe: StudentProbe,
    _ job: Job,
    _ body: () async throws -> Int
) async throws -> Int {
    await probe.begin(job.id)
    do {
        let value = try await body()
        await probe.end(job.id)
        return value
    } catch {
        await probe.end(job.id)
        throw error
    }
}

fileprivate func studentSpinUntilCancelled() async throws -> Int {
    while true {
        try Task.checkCancellation()
        await Task.yield()
    }
}

fileprivate func studentJobs(_ count: Int) -> [Job] {
    (1...count).map { Job(id: "j\($0)", input: $0) }
}

final class TaskProcessorStudentTests: XCTestCase {

    func testStudentRejectsNonPositiveMaximumConcurrency() {
        XCTAssertThrowsError(try TaskProcessor(maximumConcurrency: 0)) { error in
            XCTAssertEqual(error as? TaskProcessorError, .nonPositiveMaximumConcurrency)
        }
        XCTAssertThrowsError(try TaskProcessor(maximumConcurrency: -3)) { error in
            XCTAssertEqual(error as? TaskProcessorError, .nonPositiveMaximumConcurrency)
        }
    }

    func testStudentDuplicateIDThrowsFirstRepeatedIDAndStartsNoWorker() async throws {
        let probe = StudentProbe()
        let processor = try TaskProcessor(maximumConcurrency: 2)
        let jobs = [
            Job(id: "a", input: 1), Job(id: "b", input: 2), Job(id: "c", input: 3),
            Job(id: "b", input: 4), Job(id: "a", input: 5),
        ]

        do {
            _ = try await processor.process(jobs) { job in
                try await studentTracked(probe, job) { job.input }
            }
            XCTFail("Expected duplicateID to be thrown")
        } catch {
            XCTAssertEqual(error as? TaskProcessorError, .duplicateID("b"))
        }

        let started = await probe.started
        XCTAssertTrue(started.isEmpty, "No worker may start when a duplicate exists")
    }

    func testStudentEmptyJobsReturnsEmptyAndStartsNoWorker() async throws {
        let probe = StudentProbe()
        let processor = try TaskProcessor(maximumConcurrency: 4)

        let results = try await processor.process([]) { job in
            try await studentTracked(probe, job) { job.input }
        }

        XCTAssertEqual(results, [])
        let started = await probe.started
        XCTAssertTrue(started.isEmpty)
    }

    func testStudentNeverExceedsLimitAndStartsNextJobWhenSlotFrees() async throws {
        let probe = StudentProbe()
        let processor = try TaskProcessor(maximumConcurrency: 2)
        let jobs = studentJobs(5)
        var gates: [String: StudentGate] = [:]
        for job in jobs { gates[job.id] = StudentGate() }
        let gatesForWorkers = gates

        let task = Task {
            try await processor.process(jobs) { job in
                try await studentTracked(probe, job) {
                    await gatesForWorkers[job.id]!.wait()
                    return job.input * 10
                }
            }
        }

        await probe.waitForStarted(2)
        let firstTwo = await probe.started
        XCTAssertEqual(Set(firstTwo), ["j1", "j2"])

        await gates["j1"]!.open()
        await probe.waitForStarted(3)
        let afterFirstRelease = await probe.started
        XCTAssertEqual(afterFirstRelease[2], "j3")

        await gates["j2"]!.open()
        await probe.waitForStarted(4)
        let afterSecondRelease = await probe.started
        XCTAssertEqual(afterSecondRelease[3], "j4")

        await gates["j3"]!.open()
        await probe.waitForStarted(5)
        let afterThirdRelease = await probe.started
        XCTAssertEqual(afterThirdRelease[4], "j5")

        await gates["j4"]!.open()
        await gates["j5"]!.open()

        let results = try await task.value
        XCTAssertEqual(results.map(\.id), jobs.map(\.id))
        XCTAssertEqual(
            results.map(\.outcome),
            [.succeeded(10), .succeeded(20), .succeeded(30), .succeeded(40), .succeeded(50)]
        )
        let maxActive = await probe.maxActive
        XCTAssertEqual(maxActive, 2, "Active workers must reach but never exceed the limit")
    }

    func testStudentResultsKeepInputOrderWhenCompletionIsOutOfOrder() async throws {
        let probe = StudentProbe()
        let processor = try TaskProcessor(maximumConcurrency: 3)
        let gateA = StudentGate()
        let gateB = StudentGate()
        let jobs = [Job(id: "a", input: 1), Job(id: "b", input: 2), Job(id: "c", input: 3)]

        let task = Task {
            try await processor.process(jobs) { job in
                try await studentTracked(probe, job) {
                    switch job.id {
                    case "a": await gateA.wait()
                    case "b": await gateB.wait()
                    default: break
                    }
                    return job.input * 100
                }
            }
        }

        await probe.waitForFinished(1)
        await gateB.open()
        await probe.waitForFinished(2)
        await gateA.open()

        let results = try await task.value
        let finished = await probe.finished
        XCTAssertEqual(finished, ["c", "b", "a"])
        XCTAssertEqual(results.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(
            results.map(\.outcome),
            [.succeeded(100), .succeeded(200), .succeeded(300)]
        )
    }

    func testStudentMapsSuccessFailureAndCancellationErrorAndContinues() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 1)
        let jobs = [
            Job(id: "ok-1", input: 7),
            Job(id: "bad", input: 0),
            Job(id: "cancel", input: 0),
            Job(id: "ok-2", input: 9),
        ]

        let results = try await processor.process(jobs) { job in
            switch job.id {
            case "bad": throw StudentTestError.boom
            case "cancel": throw CancellationError()
            default: return job.input + 1
            }
        }

        XCTAssertEqual(results, [
            JobResult(id: "ok-1", outcome: .succeeded(8)),
            JobResult(id: "bad", outcome: .failed),
            JobResult(id: "cancel", outcome: .cancelled),
            JobResult(id: "ok-2", outcome: .succeeded(10)),
        ])
    }

    func testStudentCallerCancellationCancelsRunningAndQueuedJobs() async throws {
        let probe = StudentProbe()
        let processor = try TaskProcessor(maximumConcurrency: 2)
        let jobs = studentJobs(5)

        let task = Task {
            try await processor.process(jobs) { job in
                try await studentTracked(probe, job) { try await studentSpinUntilCancelled() }
            }
        }

        await probe.waitForStarted(2)
        task.cancel()

        let results = try await task.value
        XCTAssertEqual(results.map(\.id), jobs.map(\.id))
        XCTAssertTrue(results.allSatisfy { $0.outcome == .cancelled })
        let started = await probe.started
        XCTAssertEqual(started.count, 2, "No queued job may start after cancellation")
    }

    func testStudentCompletedResultsSurviveLaterCancellation() async throws {
        let probe = StudentProbe()
        let processor = try TaskProcessor(maximumConcurrency: 1)
        let jobs = studentJobs(3)

        let task = Task {
            try await processor.process(jobs) { job in
                try await studentTracked(probe, job) {
                    if job.id == "j1" { return 111 }
                    return try await studentSpinUntilCancelled()
                }
            }
        }

        await probe.waitForStarted(2)
        task.cancel()

        let results = try await task.value
        XCTAssertEqual(results, [
            JobResult(id: "j1", outcome: .succeeded(111)),
            JobResult(id: "j2", outcome: .cancelled),
            JobResult(id: "j3", outcome: .cancelled),
        ])
    }

    func testStudentAlreadyCancelledCallerStartsNothing() async throws {
        let probe = StudentProbe()
        let processor = try TaskProcessor(maximumConcurrency: 3)
        let startGate = StudentGate()
        let jobs = studentJobs(4)

        let task = Task {
            await startGate.wait()
            return try await processor.process(jobs) { job in
                try await studentTracked(probe, job) { job.input }
            }
        }
        task.cancel()
        await startGate.open()

        let results = try await task.value
        XCTAssertEqual(results.map(\.id), jobs.map(\.id))
        XCTAssertTrue(results.allSatisfy { $0.outcome == .cancelled })
        let started = await probe.started
        XCTAssertTrue(started.isEmpty)
    }

    func testStudentRetryPolicyRejectsNonPositiveAttempts() {
        XCTAssertThrowsError(try RetryPolicy(maximumAttempts: 0)) { error in
            XCTAssertEqual(error as? RetryPolicyError, .nonPositiveMaximumAttempts)
        }
        XCTAssertThrowsError(try RetryPolicy(maximumAttempts: -1)) { error in
            XCTAssertEqual(error as? RetryPolicyError, .nonPositiveMaximumAttempts)
        }
        XCTAssertEqual(try RetryPolicy(maximumAttempts: 2).maximumAttempts, 2)
    }

    func testStudentRetryRecoversBeforeLimitWithExactAttemptNumbers() async throws {
        let probe = StudentProbe()
        let processor = try TaskProcessor(maximumConcurrency: 2)
        let policy = try RetryPolicy(maximumAttempts: 4)
        let jobs = [Job(id: "flaky", input: 5), Job(id: "steady", input: 6)]

        let results = try await processor.process(jobs, retryPolicy: policy) { job, attempt in
            await probe.recordAttempt(attempt, for: job.id)
            if job.id == "flaky" && attempt < 3 { throw StudentTestError.boom }
            return job.input
        }

        XCTAssertEqual(results, [
            JobResult(id: "flaky", outcome: .succeeded(5)),
            JobResult(id: "steady", outcome: .succeeded(6)),
        ])
        let attempts = await probe.attempts
        XCTAssertEqual(attempts["flaky"], [1, 2, 3])
        XCTAssertEqual(attempts["steady"], [1])
    }

    func testStudentRetryFailsAfterFinalAttemptAndNeverRetriesCancellation() async throws {
        let probe = StudentProbe()
        let processor = try TaskProcessor(maximumConcurrency: 1)
        let policy = try RetryPolicy(maximumAttempts: 3)
        let jobs = [Job(id: "always-fails", input: 1), Job(id: "cancels", input: 2)]

        let results = try await processor.process(jobs, retryPolicy: policy) { job, attempt in
            await probe.recordAttempt(attempt, for: job.id)
            if job.id == "cancels" { throw CancellationError() }
            throw StudentTestError.boom
        }

        XCTAssertEqual(results, [
            JobResult(id: "always-fails", outcome: .failed),
            JobResult(id: "cancels", outcome: .cancelled),
        ])
        let attempts = await probe.attempts
        XCTAssertEqual(attempts["always-fails"], [1, 2, 3])
        XCTAssertEqual(attempts["cancels"], [1])
    }

    func testStudentRetriesStaySequentialWithinJobLevelConcurrencyLimit() async throws {
        let probe = StudentProbe()
        let processor = try TaskProcessor(maximumConcurrency: 2)
        let policy = try RetryPolicy(maximumAttempts: 3)
        let jobs = studentJobs(6)

        let results = try await processor.process(jobs, retryPolicy: policy) { job, attempt in
            try await studentTracked(probe, Job(id: "\(job.id)#\(attempt)", input: job.input)) {
                await Task.yield()
                if attempt < 2 { throw StudentTestError.boom }
                return job.input * 2
            }
        }

        XCTAssertEqual(results.map(\.id), jobs.map(\.id))
        XCTAssertEqual(
            results.map(\.outcome),
            [.succeeded(2), .succeeded(4), .succeeded(6), .succeeded(8), .succeeded(10), .succeeded(12)]
        )
        let maxActive = await probe.maxActive
        XCTAssertLessThanOrEqual(maxActive, 2)
    }
}
