# Implementation Plan

## Approach

**1. Check the input first.**
- `init` throws `.nonPositiveMaximumConcurrency` if the limit is 0 or less.
- In `process` I go through the jobs from left to right and keep a `Set` of IDs. The first job whose ID is already in the set throws `.duplicateID(id)`. So for `[a, b, c, b, a]` the answer is `"b"`, not `"a"`.
- This happens before any task starts, so no worker can run on bad input.
- An empty list returns `[]` right away.

**2. Run jobs with a limit.**
- I use one `withTaskGroup`.
- I start jobs while `active < limit`. Then I wait for ONE job to finish with` group.next()`, save its result, lower `active`, and start the next job from the left. So a free slot always goes to the next unstarted job.
- I add 1 to `active` before `addTask` and subtract it after `group.next()` returns. A job may have already finished but still be counted until its result is collected. This is safe because the counter can temporarily overestimate the number of running jobs, so the concurrency limit is never exceeded.
- Before every start I check `Task.isCancelled`.

**3. Turn errors into outcomes inside the child task.**
The child task never throws. It returns a `JobOutcome`:
- worker returns a number -> `.succeeded(number)`
- worker throws `CancellationError` -> `.cancelled`
- worker throws any other error -> `.failed`

I did it this way because a child that throws could stop the group, and the rules say the other jobs must continue.

**Cancellation.**
- `process` runs on the caller's task, so cancelling the caller also cancels the child tasks.
- After that I do not start new jobs.
- Running workers that check cancellation throw `CancellationError` and become` .cancelled`.
- Cancellation is cooperative. If a worker ignores cancellation and returns a value normally, its result may still be `.succeeded`.
- Jobs that never started become `.cancelled`.
- Jobs that already finished keep their result.
- `process` returns the results. It does not throw because of cancellation.

## Retry bonus (decisions)

1. **One shared function for both versions.** The normal `process` and the retry `process` both call the private `run`. Only the small closure inside is different. I did this so the rules (limit, order, cancel) can not become different in two copies of the same loop.
2. **Retries are a loop inside the same child task.** Attempt 1, 2, 3 run one after another. A job keeps its one slot, so retries cannot break the limit, two attempts of one job never overlap, and waiting jobs do not jump ahead.
3. **`RetryPolicy` checks itself.** Its `init` throws` .nonPositiveMaximumAttempts` for 0 or less, so a bad policy never exists.
4. **Attempt numbers start at 1.** With `maximumAttempts: 1` it works like the normal version.
5. **Outcomes:** success -> `.succeeded` right away (no extra attempt);
   `CancellationError` -> `.cancelled`, never retried; ordinary error -> retry until the last attempt, then `.failed`.
6. **A case the rules do not describe:** the caller is cancelled and an attempt then throws an ordinary error. I stop retrying and return `.failed` because `Task.isCancelled` is checked before another attempt. I chose this behavior as my interpretation of an unspecified case. The outcome depends on the error thrown, while cancellation prevents another retry.

## Milestones

- [x] Validate configuration and all job IDs before starting work.
- [x] Schedule jobs within the concurrency limit and preserve input order.
- [x] Map success, ordinary errors, and cancellation outcomes.
- [x] Handle caller cancellation and never-started jobs.
- [x] Add at least six distinct student-authored tests and run `swift test`.
- [x] Optional: retry policy extension.

## Risks and checks

| What can go wrong | How I check it |
| --- | --- |
| More jobs run at once than the limit | The probe counts active workers. A test checks that the max is exactly the limit (2). |
| Wrong job takes a free slot | A test opens gates one by one and checks that j3, then j4, then j5 start in this order. |
| Finish order shows in the results | A test forces finish order c, b, a and checks the result order is a, b, c. |
| One failing job stops the others | Test with limit 1: a failing job and a cancelled job are in the middle, later jobs must still succeed. |
| Cancel is seen too late | `Task.isCancelled` is checked before each start. Tests: cancel while 2 workers run; cancel before `process` starts. |
| Retry uses extra slots | The probe counts every attempt. A test checks the max active is not above the limit. |

## Test strategy

Tests in `Tests/TaskProcessorTests/`: validation, empty list, limit and slot refill, order, outcomes, cancellation, retry.

Weak points I know about:
- A test cannot prove "job 3 did not start too early" without waiting, and time-based checks are not allowed. So the limit test checks it mostly through the max-active counter.
- A gate test would hang instead of failing if the scheduler was broken in the future (no default timeout).

## Changes

- At first the retry loop did not check cancellation when handling ordinary errors. I changed it to stop retrying if the caller is cancelled, so it does not start another attempt after cancellation has been noticed.
