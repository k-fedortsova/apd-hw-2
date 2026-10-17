public struct Job: Sendable, Equatable {
    public let id: String
    public let input: Int

    public init(id: String, input: Int) {
        self.id = id
        self.input = input
    }
}

public enum JobOutcome: Sendable, Equatable {
    case succeeded(Int)
    case failed
    case cancelled
}

public struct JobResult: Sendable, Equatable {
    public let id: String
    public let outcome: JobOutcome

    public init(id: String, outcome: JobOutcome) {
        self.id = id
        self.outcome = outcome
    }
}

public enum TaskProcessorError: Error, Equatable {
    case nonPositiveMaximumConcurrency
    case duplicateID(String)
}

public actor TaskProcessor {
    private let maximumConcurrency: Int
    public init(maximumConcurrency: Int) throws {
        guard maximumConcurrency > 0 else {
            throw TaskProcessorError.nonPositiveMaximumConcurrency
        }
        self.maximumConcurrency = maximumConcurrency
    }

    public func process(
        _ jobs: [Job],
        worker: @escaping @Sendable (Job) async throws -> Int
    ) async throws -> [JobResult] {
        try await run(jobs) { job in
            do {
                return .succeeded(try await worker(job))
            } catch is CancellationError {
                return .cancelled
            } catch {
                return .failed
            }
        }
    }

    fileprivate func run(
        _ jobs: [Job],
        execute: @escaping @Sendable (Job) async -> JobOutcome
    ) async throws -> [JobResult] {
        var seen = Set<String>()
        for job in jobs {
            if !seen.insert(job.id).inserted {
                throw TaskProcessorError.duplicateID(job.id)
            }
        }

        guard !jobs.isEmpty else { return [] }

        let limit = maximumConcurrency
        let outcomes: [JobOutcome?] = await withTaskGroup(
            of: (Int, JobOutcome).self,
            returning: [JobOutcome?].self
        ) { group in
            var outcomes = [JobOutcome?](repeating: nil, count: jobs.count)
            var nextIndex = 0
            var active = 0

            while true {
                while active < limit, nextIndex < jobs.count, !Task.isCancelled {
                    let index = nextIndex
                    let job = jobs[index]
                    nextIndex += 1
                    active += 1
                    group.addTask { (index, await execute(job)) }
                }
                guard let (index, outcome) = await group.next() else { break }
                outcomes[index] = outcome
                active -= 1
            }
            return outcomes
        }
        return jobs.enumerated().map { offset, job in
            JobResult(id: job.id, outcome: outcomes[offset] ?? .cancelled)
        }
    }
}


public struct RetryPolicy: Sendable, Equatable {
    public let maximumAttempts: Int

    public init(maximumAttempts: Int) throws {
        guard maximumAttempts > 0 else {
            throw RetryPolicyError.nonPositiveMaximumAttempts
        }
        self.maximumAttempts = maximumAttempts
    }
}

public enum RetryPolicyError: Error, Equatable {
    case nonPositiveMaximumAttempts
}

public extension TaskProcessor {
    func process(
        _ jobs: [Job],
        retryPolicy: RetryPolicy,
        worker: @escaping @Sendable (Job, Int) async throws -> Int
    ) async throws -> [JobResult] {
        let maximumAttempts = retryPolicy.maximumAttempts
        return try await run(jobs) { job in
            var attempt = 1
            while true {
                do {
                    return .succeeded(try await worker(job, attempt))
                } catch is CancellationError {
                    return .cancelled
                } catch {
                    if attempt >= maximumAttempts || Task.isCancelled {
                        return .failed
                    }
                    attempt += 1
                }
            }
        }
    }
}
