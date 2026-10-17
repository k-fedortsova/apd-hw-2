# Agent Worklog

| Date | Tool / model | Task or recommendation | My review and decision | Evidence |
| ---------- | ------------ | ---------------------- | ---------------------- | -------- |
| 2026-10-17 | Claude Sonnet 5.5 | Read assignment, then asked Claude to explain the parts I did not get: cooperative cancellation, why `Sendable` is needed, what a task group is. | Accepted as learning and wrote plan draft. | PLAN.md |
| 2026-10-17 | Claude Sonnet 5.5 | Drafted `Sources/TaskProcessor/TaskProcessor.swift`: validation preflight, shared `run` engine, outcome mapping, `RetryPolicy` extension. | Read and rejected, because it was not my logic. | TaskProcessor.swift |
| 2026-10-17|  Claude Sonnet 5.5| Asked for a detailed explanation of the retry decisions and for a check of my final plan.|  Accepted. It found some missing parts. |PLAN.md |
| 2026-10-17 | Claude Sonnet 5.5 | Drafted `TaskProcessorStudentTests.swift.` | Checked each test maps to a graded category and that none relies on timing. Accept, but make my own changes and fixes. | TaskProcessorStudentTests.swift |
| 2026-10-17 | Claude Sonnet 5.5 | Proposed the design: one task group, sliding window, child tasks that never throw, results saved by index. | Checked it against each row of the rules table. Kept "child never throws" so one failure cannot stop other jobs. | PLAN.md, TaskProcessor.swift 
|  2026-10-17|  Claude Sonnet 5.5|Asked to review my final version of 13 tests. |  Accepted. All changes were useful. |TaskProcessorStudentTests.swift |
|  2026-10-17| ChatGPT (GPT-6)  | Asked for help reviewing and improving the implementation plan and agent worklog.  |  Used the suggestions to make the documentation clearer and more accurate. Reviewed the proposed changes against my implementation instead of treating the suggestions as proof that the code works. |  PLAN.md, AGENT\_WORKLOG.md |

## Final review

- **What the tests cover:** limit and slot refill, input-order results, outcome mapping, cancellation (running, queued, already cancelled, finished results kept), and retry (attempt numbers, limit, no retry after cancellation).
- **What is mine and what is Claude's:** Claude wrote some of implementation and the tests. I read them, ran them, rewrite some parts, and checked the plan against the code. Also text was polished with AI.
