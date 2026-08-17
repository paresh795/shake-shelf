# Shake Shelf — Shelf State History & Session Restore

## 1. Problem statement

The shelf is ephemeral by design: it holds file references while you shuffle files between apps. But that ephemerality is also its weakness — when the shelf is cleared, closed, or the app quits, the working set of files you had staged is gone with it.

**Goal:** Let the user restore a *previous working state* of the shelf — the exact set of files that was sitting there at some earlier time — so accidental clears, crashes, or "I need that group of files again" moments are recoverable with one click.

**Non-goals (deliberately out of scope — these keep the app lightweight):**

- ❌ File *content* versioning. We record *references* (paths), never copies of file data.
- ❌ Recovering deleted/moved files. If the file itself is gone from disk, we cannot resurrect it (same limitation as the shelf today — `existing()` filtering).
- ❌ Cloud sync, cross-device history, or telemetry of any kind.
- ❌ A full "timeline browser" window. History lives in menus only.

## 2. Terminology

| Term | Meaning |
|---|---|
| **State** | The ordered list of file URLs currently on the shelf. |
| **Session** | A maximal period during which the shelf held the *same* state. A session has a start time, last-seen time, and one state. |
| **Snapshot** | An observation that a state existed at a point in time. Snapshots collapse into sessions. |
| **Restore** | Replacing the shelf's current state with a session's state. |

## 3. Data model

A session is stored as:

```
ShelfSession:
  urls:       [String]   // standardized file paths, in shelf order, deduplicated
  firstSeen:  Date       // when this stable state began
  lastSeen:   Date       // when this state was last observed alive
```

Derived at read time (never stored): duration = lastSeen − firstSeen, item count = urls.count.

Storage: one plist at `~/Library/Application Support/Shake Shelf/History.plist`, encoded with the same approach as `ShelfItemPersistence` (PropertyListEncoder, atomic write, background queue).

## 4. Recording policy — when we snapshot

The shelf is a *state machine*: it transitions on discrete events. Every transition is a candidate snapshot.

| Trigger | Behavior |
|---|---|
| `add(urls)` | Debounce 2 s, then record new state. |
| `removeFromShelf(url)` | Debounce 2 s, then record new state. |
| **Clear (X / Clear Shelf / Clear menu)** | **Record the state that existed immediately BEFORE clearing**, synchronously, then clear. This is the "oops" recovery case and the single highest-value trigger. |
| Restore (this feature) | Record the pre-restore state first (debounced), then the restored state becomes the new current state (recorded after debounce). |
| Heartbeat | While the shelf is non-empty and unchanged, every 60 s re-observe the current state (extends the session's `lastSeen`). |
| App termination | If the shelf is non-empty, record the current state during `applicationWillTerminate`. |

**Never recorded:** empty states, mid-change states, states observed while `pendingExternalDrops > 0` (promised files still landing).

## 5. Deduplication — snapshot → session

Snapshots collapse by content identity (path set, order-insensitive):

- New snapshot with content **equal** to the current session → extend `lastSeen` of that session. No new record.
- New snapshot with content **different** → close the current session (its `lastSeen` is final), start a new session with `firstSeen = lastSeen = now`.
- Content equality is computed on the deduplicated, sorted path list (hash the joined paths).

This means: 40 minutes of working with the same 6 files = **one** session, not 40. That matches the user's mental model ("if it stayed open, I was working with those files").

## 6. Retention policy

- Prune sessions whose `lastSeen` is older than **7 days** (168 hours).
- Hard cap: keep at most **200 sessions** (oldest first) even inside the window — bounds file size under pathological usage.
- Pruning runs on every record and on load. A pruned write is only persisted if something changed.

Budget math (worst case): 200 sessions × 50 paths × ~80 bytes ≈ **≤ 1 MB** disk, typically well under 100 KB. In-memory: the same array, loaded once. Negligible.

## 7. Restore semantics

- **Replace or append, chosen by the user.** When the current shelf is non-empty, a confirmation offers **Replace / Append / Cancel**. Replace swaps the shelf's state for the session's; append adds the session's files to the current shelf (deduplicated by the normal `add` path). If the current shelf is empty, the restore happens immediately (replace and append are identical then).
- **Missing files are filtered at restore time** via `FileManager.fileExists`, and the count is surfaced *in the confirmation itself*: *"Replace the current shelf (N files) with this session (M files)? 2 files were moved or deleted."*
- **Post-restore state:** restore collapses overview/list modes to the stack, clears selection/hover, triggers persistence save (if the persistence setting is on), and the restored state itself becomes history (it is a new state, recorded via the normal trigger path). The pre-restore state is also recorded (so the restore itself is undoable via history).
- **Restoring an empty/expired session:** sessions with 0 files after missing-file filtering restore to an empty shelf (valid: "get me back to before I started").

## 8. UI/UX

History lives in two places (no new window):

1. **Menu bar icon → History submenu:**
   - Top-level item: **Restore Last Session** (key equivalent ⌃⌥R), disabled when there is no history.
   - Separator, then up to **12 most recent sessions**, each: `Today 2:14 PM · 5 files · 23 min` — local date/time, relative day (Today/Yesterday/<weekday>/<date>), item count, duration.
   - Selecting an item restores that session.
   - A "Clear History…" item at the bottom, with confirmation.
2. **Right-click shelf → History submenu** — same session list (no keyboard accelerator needed).

Menu construction cost: only when the menu is opened. No timers or UI updates while history is idle.

## 9. Edge cases & failure modes

| Case | Behavior |
|---|---|
| History.plist corrupt/unreadable | Discard file, start empty, log via Diagnostics. Never crash. |
| Write fails (disk full, permission) | Log via Diagnostics; keep sessions in memory for the session. |
| Rapid add/remove burst | Debounce (2 s) coalesces; final state wins. |
| Drag-in-progress when restoring | Not reachable (menus can't open mid-drag); no special handling. |
| Promised files pending when restoring | Pending completions land into the restored state (normal `add` path). Acceptable; noted. |
| File moved/deleted between snapshot and restore | Filtered; count surfaced in the confirmation/result. |
| App crashed | Snapshot from last save still present; missing `APP TERMINATED NORMALLY` in the diagnostics log is the crash signal. |
| Second app instance | Atomic plist writes keep corruption risk negligible; last-writer-wins. |
| Locale/timezone | Dates formatted with the user's current locale at display time. |
| History while smoke test runs | Smoke test uses the same storage; tests clean up after themselves. |
| Shelf empty for the entire app lifetime | No sessions, no file, no timer. |

## 10. Performance budget

- **CPU:** one plist encode (≤ 200 sessions) on a background queue per recorded change; a single 60 s repeating timer, active **only while the shelf is non-empty**. All fast paths (draw, drag, drop) untouched.
- **Memory:** one array of ≤ 200 small structs. No caches, no observers.
- **Disk:** ≤ ~1 MB worst case, atomically written, debounced.
- **Battery:** heartbeat only extends a timestamp; no network, no spotlight.

## 11. Testing plan

Unit tests (ShakeShelfCore — `ShelfHistoryStore`):

1. Snapshot equal-content extends the session (no new record).
2. Snapshot different content closes and opens a session.
3. `firstSeen`/`lastSeen` are correct across merges.
4. Debounce coalescing is honored by the recorder (injectable clock + debounce).
5. Retention: sessions older than 72 h are pruned; cap of 200 enforced.
6. Persistence round-trip (encode → decode → equal).
7. Corrupt file → empty store, no throw.
8. Missing files filtered at restore, count returned.
9. Restore of an empty session → empty result.
10. Order of URLs preserved through save/load.
11. Clear-before-empty: recording on clear captures the pre-clear state.
12. Heartbeat does not create a new session for identical content.

In-app smoke test additions:

- Record → restore → verify shelf contents match; verify the restored state persisted (when enabled).
- Verify clear-before-clear recording produced a restorable session.
- Verify history menu items are populated from the store.

## 12. Implementation plan

1. **Core:** `ShelfSession` + `ShelfHistoryStore` (persistence, pruning, corruption handling) in ShakeShelfCore, with an injectable clock and debounce for testability. All 12+ unit tests.
2. **Recorder:** a small `ShelfHistoryRecorder` in the app target wired into ShelfView's `add`/`removeFromShelf`/`clearShelfContents`/restore and AppDelegate's terminate; heartbeat timer while non-empty.
3. **UI:** menu-bar History submenu + shelf right-click History submenu + restore confirmation flow.
4. **Verification:** unit tests, smoke test additions, manual scenario walkthrough (user), diagnostics log review.

## 13. Decisions (confirmed)

1. **Retention window:** 7 days.
2. **Restore = replace or append**, chosen via the confirmation dialog (Replace / Append / Cancel) when the current shelf is non-empty.
3. **Clearing the shelf records the pre-clear state** (the "oops" case is recoverable).
4. **"Restore Last Session" accelerator:** ⌃⌥R.
5. History entry points: menu-bar submenu + right-click submenu. No dedicated window.
