## EmojiMatch

App-specific guidance for `apps/EmojiMatch`:

- The `EmojiMatch` app-local targets use `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` in
  [Project.swift](Project.swift).
- The `EmojiMatch` app-local targets also enable `SWIFT_APPROACHABLE_CONCURRENCY = YES` in
  [Project.swift](Project.swift).
- Within these app-local targets, prefer relying on main-actor-by-default instead of repeating
  `@MainActor` annotations unless they improve clarity at an API boundary.
