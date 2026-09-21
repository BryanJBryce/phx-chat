# Implementation roadmap

Planning only: application implementation has not begun. Build the single shared room in the four slices below, keeping correctness and a minimal interface ahead of additional features.

## Existing repository

- Phoenix starter under `App` / `AppWeb`; `/` serves the welcome page. No chat schemas, migrations, context, LiveView, or Presence module exist.
- Locked versions: Phoenix 1.8.14, LiveView 1.2.12, Ecto 3.14.2, Ecto SQL 3.14.0, Postgrex 0.22.4. Repo, PubSub, LiveView transport, and signed cookie sessions are configured.
- Tailwind v4, DaisyUI defaults, core inputs, layouts, SQL Sandbox support, and generated page/error tests exist. Reuse them; add no UI framework. README is boilerplate.
- Git contains starter and guideline/lockfile commits. Preserve existing work. Local tools are Elixir 1.20.1 / OTP 29 and a PostgreSQL 18 client; the database server version remains unverified. The local test-queue resolver reports this repository is not enrolled.
- Baseline `mix precommit` passed during planning: five starter tests, with no tracked application changes. This verifies the existing test database connection, not the future chat behavior.

## Decisions and assumptions

### Persistence, identity, and session

Use `App.Chat` for identity creation/reuse, user/history queries, message creation, validation, and persisted-change notifications. Add `App.Chat.User` and `App.Chat.Message`.

- Users have a generated primary key, trimmed display `name`, server-derived `normalized_name`, and timestamps. Match with `String.trim/1` then `String.downcase/1`; internal whitespace and accents remain significant. Preserve the first stored spelling. Reject whitespace-only names.
- Put a non-null unique index on `users.normalized_name` in Postgres. Look up the normalized name, reuse the persisted user if found, otherwise insert. Do not accept a normalized name from the browser. Concurrent first joins for an equivalent name are outside the supported assumption: no automatic conflict recovery or dedicated join-race tests. Keep the database constraint and ordinary changeset error handling so a conflict cannot create duplicate identities. See `ASSUMPTIONS.md`.
- **Entering an existing name selects that identity; anyone can do so without authentication.** Store the selected user ID in the signed Phoenix session and resolve it against the database on mount. Missing or invalid identity returns the join experience.
- A CSRF-protected `POST /join` controller action performs the authoritative create/reuse operation, writes the cookie session, and redirects to `/`. The LiveView join form validates inline and uses `phx-trigger-action` for that HTTP handoff. The controller also validates direct submissions and returns useful inline errors. A LiveView socket assign alone cannot preserve identity across refreshes.
- Messages have a Postgres `uuid` primary key, non-null user foreign key, text body, and UTC timestamp. Generate UUIDv7 on the server using the installed Ecto support; no extra UUID package or Postgres UUID-generation extension is needed. [Ecto UUID documentation](https://ecto.hexdocs.pm/Ecto.UUID.html)
- Derive `user_id` from the session-resolved user held in the LiveView. Accept only message content from the form; never cast sender, ID, or timestamp from submitted parameters. Reject whitespace-only bodies, preserve internal newlines, and render escaped text with readable UTC timestamps.

`ASSUMPTIONS.md` records join concurrency, name reuse, identity selection without authentication, and **we do not care about sub-millisecond accuracy for chat**. Also assume shared browser-session identity across tabs and that refresh starts at the bottom; add these details there during implementation. Before joining, show the roster and join form; load history after joining.

### Ordered updates: append with a full-reload fallback

Streams control rendering, not database/client convergence. The [streams introduction](https://fly.io/phoenix-files/phoenix-dev-blog-streams/) explains their memory benefit; the [chat tutorial](https://fly.io/phoenix-files/building-a-chat-app-with-liveview-streams/) demonstrates incremental messages and older-history loading.

| Approach | Benefit | Cost and correctness obligations |
| --- | --- | --- |
| Persist, broadcast `messages_changed`, reload all history ordered by ID | One authoritative query handles initial history, late commits, repeated notifications, and reconnects. | Every notification causes a full query and render per joined connection; work grows with history and participant count. |
| Broadcast individual messages and insert them incrementally into streams | Smaller queries and patches per new message. | Must locate each message's canonical position, deduplicate it, handle lower IDs arriving later, and reconcile loading/reconnect races. Appending in PubSub arrival order is incorrect. |
| Append larger IDs; reload for older or repeated IDs | In-order messages need only a stream append; the ordered query resolves everything else. | Keep the largest displayed ID. Out-of-order and duplicate events still incur a full reload/reset. |

**Choose the append-with-reload-fallback approach**, with stable message DOM IDs and one `last_message_id` assign:

1. On mount/reconnect, load all history in ascending ID order into the stream. Set `last_message_id` to the largest loaded ID, or `nil` for an empty history.
2. Broadcast `{:message_created, message}` after persistence, with the sender preloaded.
3. If history is empty or the incoming ID is strictly greater than `last_message_id`, append with `stream_insert` and advance that assign.
4. Otherwise, reload **all** history, replace the stream with `stream(..., reset: true)`, and recompute `last_message_id` from the result. This handles both late smaller IDs and repeated events without a separate ID set or positional insertion logic.

Compare canonical UUID values in the same order as Postgres. The largest displayed ID is only an append decision, never a database query watermark: `WHERE id > last_message_id` could miss a smaller ID committed later. `stream_insert` does not automatically sort or reposition existing items (confirmed in the installed LiveView source).

Query `ORDER BY messages.id ASC`, preload senders, and apply no limit. Generation order, commit order, timestamps, and PubSub delivery order are not ordering guarantees. If B commits before smaller ID A, the subsequent reload places A before B. Clients may briefly have different subsets while notifications are in flight; their histories converge after processing them.

Broadcast only after a successful database write has committed, outside any transaction containing it. Include the sending LiveView in notifications and use the same append-or-reload handler there, without a separate optimistic append. Repeated notifications trigger a reset rather than duplicate display. PubSub is not durable storage: a fresh mount/reconnect always reloads Postgres history.

### Mount and presence

Use one `AppWeb.ChatLive` at `/` and one supervised `AppWeb.Presence` after PubSub. No room process, separate browser Channel, or authentication system is needed.

On **connected mount**, subscribe to chat changes and presence notifications **before querying initial state**, then resolve the session identity, track the joined LiveView PID under the string form of its user ID, and load the roster/presence snapshot and joined user's history. Events received while queries run remain queued: apply the append-or-reload rule to messages, including events already represented in the initial snapshot. Roster events trigger fresh reads. Unjoined visitors ignore message events. Disconnected rendering neither subscribes nor tracks.

Build the roster from **every persisted user**, sorted by normalized name and ID. Overlay online status from Presence: at least one metadata entry means Online. On `users_changed` or `presence_diff`, read the current roster/presence state and reset its stream. Never interpret one connection's leave as the whole user becoming offline. Visitors subscribe and see changes but are not tracked. Presence monitors the LiveView processes; cleanup must not depend on a browser unload event or `terminate/2`. Unexpected network loss becomes offline after disconnect detection, not instantaneously. [Presence documentation](https://phoenix.hexdocs.pm/Phoenix.Presence.html)

### History and scrolling: compare before choosing

| Method | Benefit | Cost |
| --- | --- | --- |
| Load all history | Meets the complete-history requirement directly and shares the ordered reload path. | Initial rendering, DOM size, and each reset grow with the conversation. |
| Infinite scroll with streams | Loads older messages on demand and can bound rendered content. | Needs UUID keyset cursors, page boundaries, overlap handling, late-insert reconciliation, and scroll anchoring; the initial page is only partial history. |

**Choose all history with no hidden latest-50 cutoff or stream limit.** Infinite scrolling is not part of this implementation. In-order events append one message; initial loads and fallback resets still grow with history. Bursts with out-of-order IDs or repeated notifications can cause frequent resets, with the same worst-case costs as full reloads on every event. Explain this deliberate tradeoff in the README.

Use a small hook in `assets/js/` to start at the bottom when history first mounts. Before a message patch, record whether the reader is near the bottom plus the first visible message ID and its viewport offset. After either an append or a reset, follow new messages only if already near the bottom; otherwise preserve the visible anchor, including when a late lower ID is inserted above it. The hook controls scrolling, while LiveView continues to own the streamed children.

## Implementation slices

### 1. Establish durable identities and messages

**Deliver:** A small persistence API with normalized-name identity reuse and canonical history ordering.

**Work:** Generate migrations with `mix ecto.gen.migration`; add schemas, constraints, context operations, and committed-change broadcasts. Use Ecto's UUIDv7 autogeneration and ensure the declared dependency range includes the API used.

**Verify:** Create a user, then join sequentially with equivalent trimmed/case-varied names; assert one row and the same returned identity. Include blank-name rejection. This catches broken normalization, identity reuse, and validation without testing concurrent joins. Verify persisted messages use UUIDv7 and a valid sender and that reversed insertion order is returned as ascending IDs; this catches default UUIDv4 generation and implicit database ordering.

**Complete when:** Migrations work on an empty database, targeted persistence tests pass, and failed writes produce no persisted-change notification.

### 2. Join, retain identity, and show the live roster

**Deliver:** A visitor can watch all users, join by name, refresh with the same identity, and see correct connection status.

**Work:** Replace the welcome route with `ChatLive`; add the join controller/route, signed-session handoff, Presence supervision, subscriptions before initial reads, and a roster stream. Use `<Layouts.app>`, `to_form`, and core inputs. Put the join form in the main area and explicit Online/Offline labels in the left sidebar; show errors inline without success flashes.

**Verify:** Follow an actual join form through its HTTP session handoff and refresh, including existing-name reuse and blank input. This catches identity stored only in socket state and missing server validation. In a separate multi-connection scenario, observe from an unjoined LiveView, create/join a user, open two LiveViews as that user, close one, and abruptly terminate the last. Assert all persisted users remain listed, the first closure stays Online, the last becomes Offline, and the visitor is never present. This catches incomplete rosters, missing broadcasts, and connection/user confusion.

**Complete when:** Independent observers see roster changes and presence cleanup, and session-backed refresh restores the selected identity.

### 3. Send and converge on the complete ordered conversation

**Deliver:** Joined users see all persisted messages with sender/timestamp and send multiline messages to every participant.

**Work:** Add streamed history, a multiline composer, sender enforcement, and blank-message feedback. Track `last_message_id`, append strictly larger incoming IDs, and reset from complete ordered history otherwise. Deliver persisted-message events with senders preloaded to all joined LiveViews, including the sender. Clear the composer only after persistence succeeds.

**Verify:** Use two independent LiveViews, starting empty, then a fresh mount with more than 50 persisted messages. Send through the UI and compare ordered message DOM IDs to the database: cover larger-ID appends, a lower UUIDv7 committed after a higher one, repeated events through real PubSub, and a subsequent larger-ID message after a reset. Assert each persisted message appears once. This catches truncation, arrival-order appends, stale append state, and duplicate display. Include blank submissions, an unjoined send attempt, and a forged sender parameter; these must not create unauthorized/blank rows or change attribution. Exercise a committed change during initial loading with a deterministic query barrier and independent writer, including an event already represented in the loaded snapshot. This catches missed updates and duplicate initial/live overlap without mocking the query or PubSub.

**Complete when:** All connected participants and a fresh mount converge to the same complete ID-ordered history, with validation failures leaving history unchanged.

### 4. Finish scrolling, recovery, and submission

**Deliver:** A usable minimal room and a reproducible handoff.

**Work:** Add the scroll hook and minimal responsive layout. Replace the README with dependencies, Postgres configuration/setup, running the app, test commands, and a concise architecture explanation covering ordering, Presence, and the append-with-full-reload-fallback tradeoff. Complete `ASSUMPTIONS.md` from the decisions above; keep `ROADMAP.md` as the sole execution plan.

**Verify:** Reconnect a participant after another user persisted a message while it was disconnected; verify the session identity, complete history, subsequent message delivery, and Presence registration recover. This catches reliance on transient PubSub state or stale append state. In a real browser, check initial bottom position, following while at bottom, and retaining an older visible message during both appends and fallback resets with late-ID insertion. LiveView tests do not execute the scrolling JavaScript. Also check multiline input, readable validation, and sidebar usability at narrow widths. Run the full precommit gate and follow the README from a clean test database.

**Complete when:** Recovery and browser checks pass, setup instructions reproduce the app, the full gate passes, and the repository contains the application, README, assumptions, and truthful incremental commits.

## Execution rules and remaining unknowns

- Make real incremental commits as slices pass verification, including their meaningful tests. Do not fabricate history or commit unrelated work.
- Test context, HTTP-session, and multi-LiveView behavior with real database/PubSub/Presence and stable DOM IDs. Avoid callback/helper tests, snapshots, styling assertions, repetitive permutations, and coverage/test-count targets.
- Run shared-topic tests serially. The message-during-load scenario needs an independent writer and cleanup of committed fixtures; join-race test infrastructure is out of scope. Use `start_supervised!` for workers and messages/process monitors instead of arbitrary sleeps.
- Recheck enrollment before implementation checks with `python3 ~/.codex/tools/db-test-slot/project.py --resolve`. If still unenrolled, use targeted `mix test` and final `mix precommit`; if enrolled, use the required queued equivalents. Keep one full-gate owner.
- Verify the Postgres server version and development database setup at slice 1; recheck test connectivity then. No product decision is blocked on this; UUIDv7 is generated by Ecto. Record verified setup requirements in the README.
- Keep the stated exclusions: no accounts/passwords, additional rooms, private chat, typing indicators, attachments, editing/deletion, receipts, notifications, search, custom sequencing, room GenServer, deployment work, or speculative scaling. No scope expansion is needed.
