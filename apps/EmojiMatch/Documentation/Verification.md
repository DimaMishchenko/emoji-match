# Emoji Match real-app verification

Use the [feature map](FeatureMap.md) to select affected IDs and dependent flows for each functional
change. Interact with the current built macOS app and observe those outcomes before handoff, or
report exactly what is blocked. A full feature tour is not required for every change. Update the
map when entry points/outcomes change, preserving stable IDs.

Builds and focused logic, persistence and content-transport tests provide supporting evidence.
They do not prove GUI behavior. Do not add automated UI, presentation or browser-rendering tests,
or introduce a UI-test framework. Retain the existing model/data/transport tests.

## Build the current worktree

From the repository root, use the installed `xcodebuildmcp` CLI:

```sh
xcodebuildmcp macos build --scheme EmojiMatch \
  --workspace-path "$PWD/emoji-match.xcworkspace" \
  --derived-data-path /tmp/emoji-match-derived
```

The debug app is `/tmp/emoji-match-derived/Build/Products/Debug/EmojiMatch.app`.
Source-only edits inside existing buildable folders do not require Tuist regeneration. Regenerate
with `tuist generate --no-open` when manifests, dependencies, target structure or folder membership
change. If the CLI cannot perform a required workflow, first check its installed help; use direct
`xcodebuild` only as a fallback and pipe its output through `xcbeautify` with pipeline failure enabled.

Before launching, perform read-only checks for existing Emoji Match processes and their executable
paths. Do not mistake another checkout's app or an old process for this build. Record the worktree,
current revision/dirty source state, successful build and executable path; a revision alone does not
identify uncommitted changes. Launch a fresh process and confirm its PID, executable path and launch
time match this worktree's output. Do not terminate another task's instance to make room.

## Isolated launch and fixtures

The debug-only `--verification-directory` argument in [App.swift](../AppSources/App.swift) selects
isolated defaults/history and a local library. Use a unique directory; the resolved path must begin
with `/tmp/emoji-match-` (or `/private/tmp/emoji-match-`). Other paths do not enable isolation.

```sh
verification_dir=$(mktemp -d /tmp/emoji-match-verification-XXXXXX)
/tmp/emoji-match-derived/Build/Products/Debug/EmojiMatch.app/Contents/MacOS/EmojiMatch \
  --verification-directory "$verification_dir" &
verification_pid=$!
```

Keep this launch identity and directory for the session; confirm the process is alive and owns that
executable before interacting. Isolation covers app settings/history/library, not the system
clipboard, permissions, shortcut registration or recipient documents. The defaults suite is named
`com.dimasike.EmojiMatch.verification.` followed by the directory's final path component.

Use a task-owned recipient document or local editable fixture with known starting content and a
known selection/caret. Never send real messages or change an existing user document. Use original,
nonprivate image/glyph fixtures for rich content; a screenshot of a Genmoji is not an original glyph.
Do not blindly overwrite the general clipboard for setup. Preserve its current ownership and use
controlled fixture copies; restore only while still owning the value, preserving intervening copies.

## Observe the affected outcomes

Prefer native computer-use interaction with the actual app and recipient. Bounded native AX or
keyboard helpers are allowed when needed for inspection/input; keep them task-owned and temporary.
They are not a maintained test harness. Do not document ephemeral helper paths as dependencies.
After an input action, wait for the expected window/control state rather than assuming the action
return proves completion. An inactive Settings window may consume a first click only to activate.

Choose flows from the changed IDs and their dependencies, for example:

- Picker/header changes: OPEN-01–03 and FIND-02–03, including anchored and no-anchor opening,
  drag detachment, native-close/header inset behavior, typing and dismissal.
- Library changes: affected LIB IDs, then FIND-01–02 and SEND-02–03 for saved content; include
  restart when persistence changes, and confirm source files remain intact.
- Genmoji changes: GEN-01–02 plus affected library/delivery flows. Move/resize Settings before
  clicking Create Genmoji to check its fresh, horizontally centered button anchor; observe capture,
  cancellation and visibility.
- Insertion/clipboard changes: SEND-01–03 with an owned recipient, a known selection, actual
  resulting content and an intervening copy. Cover Unicode-only and rich paths relevant to the fix.

A screenshot proves appearance, not insertion. Read the recipient's resulting text or inspect its
actual rich attachment/glyph; posting a paste event or recording usage does not prove consumption.
For rich content, distinguish inline insertion from a large attachment, filename or plain title.
Keep Finder, plain TextEdit and unknown rich-recipient gaps qualified until each is observed.

The picker is nonactivating: the recipient may remain frontmost while Emoji Match owns search
keyboard input. Verify where typing actually lands instead of requiring Emoji Match to be frontmost.
For global shortcut takeover/restoration, injected keys may miss the OS path. If so, physical user
input is required to finish that check; report it pending/blocked instead of claiming a pass.
Native Genmoji availability and system permissions can also block a path; describe the exact limit.

## Handoff and cleanup

Report selected feature IDs, build identity, actual recipient/OS scope, observed outcomes and any
failures or blocked checks. Separate build/logic results from real GUI evidence. These documents
remain acceptance guidance; do not commit screenshots, logs or session evidence to the repository.
Retain useful verification captures under the ignored `tmp/verification/emoji-match/` directory
or outside the repository. Captures are deliverables: do not delete them after inspection. Include
their locations in the handoff; cleanup applies to disposable helpers and isolated app data.

Stop only the exact task-owned PID after rechecking its identity; never kill by app name or globally
terminate CharacterPalette. Remove only the task-owned isolated app-data directory, temporary helpers
and fixtures; keep the retained verification captures. Clean the exact isolated defaults suite after app exit; do not reset production
preferences or revoke system permissions. Temporary tools must clean up their files automatically,
including on failure; retain ownership information until cleanup completes.

For SET-03, choose a skin tone in General, reopen the picker and search for a hand/person emoji;
observe the selected tone. Restart the isolated app to check persistence, then choose yellow.
Verify an explicit per-emoji variant remains unchanged and favorites/recents retain their exact
sequences. For OPEN-03, inspect a slow drag as well as the detached result: one native circled
Close control, centered alongside search, no icon swap, query/focus preserved, and usable Close.
For LIB-02, check context-menu deletion on both selected and unselected tiles, plus navigation
with Caps Lock enabled. The gallery has no footer actions or success-status area.

For GEN-01/02, compare the picker and creator content bounds (320×480) and framed bounds,
and check both activation origins: leave Settings open in the background, trigger creation from
the picker and confirm Settings does not come forward; trigger directly from Settings and confirm
it stays visible. For FIND-01, verify headings for catalog and populated saved/recent sections.

For OPEN-03, record the first held drag from both the 11-point top strip and the empty header
background below search. AppKit's native path continues tracking before its release callback;
inspect those frames as well as the final detached state. Repeat a second drag, query editing,
Close and rapid dismissal/reopening. Preserve the before/after captures in the ignored directory.
For SET-04, open the actual status menu with another app active, choose Settings, and observe
the frontmost app and key window. Repeat with minimized Settings and with a quick app switch.
