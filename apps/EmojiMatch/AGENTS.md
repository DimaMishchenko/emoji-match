## EmojiMatch

App-specific guidance for `apps/EmojiMatch`:

- The `EmojiMatch` app-local targets use `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` in
  [Project.swift](Project.swift).
- The `EmojiMatch` app-local targets also enable `SWIFT_APPROACHABLE_CONCURRENCY = YES` in
  [Project.swift](Project.swift).
- Within these app-local targets, prefer relying on main-actor-by-default instead of repeating
  `@MainActor` annotations unless they improve clarity at an API boundary.
- Keep automated verification to builds and focused logic, persistence and content-transport tests.
  Do not add UI, presentation or browser-rendering tests.
- Compatibility with earlier Emoji Match iterations is not required. Remove obsolete paths and
  update current callers instead of retaining duplicate APIs or migration layers.

## Functional changes

- Read [the feature map](Documentation/FeatureMap.md), select affected stable IDs and dependent
  flows, and update entries in the same change when entry points or observable outcomes change.
  Preserve IDs across revisions.
- Follow [real-app verification](Documentation/Verification.md): build the current worktree and
  interact with the actual macOS app to verify selected outcomes before handoff, or clearly report
  blocked checks and their limits. Builds, logic tests, screenshots and posted input events alone
  do not establish recipient insertion or system shortcut takeover.
- Verify affected flows during iteration and before handoff; a full feature tour is not required.
  Keep the existing model/data/transport tests; do not replace real-app checks with automated UI,
  presentation or browser-rendering tests.
- Retain useful screenshots and recordings under ignored `tmp/verification/emoji-match/` or outside
  the repository. Do not delete captures after inspection or commit them.
- Use isolated debug storage and task-owned recipient fixtures. Preserve clipboard ownership and
  unrelated user data; clean only task-owned processes/files as described in the guide.
