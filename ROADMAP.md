# Implementation roadmap

Implementation is active; see the execution record below. Model users, rooms, and messages, while displaying one shared room in the four slices below. Keep correctness and a minimal interface ahead of additional features.

## Existing repository

- Phoenix starter under `App` / `AppWeb`; `/` serves the welcome page. No chat schemas, migrations, context, LiveView, or Presence module exist.
- Locked versions: Phoenix 1.8.14, LiveView 1.2.12, Ecto 3.14.2, Ecto SQL 3.14.0, Postgrex 0.22.4. Repo, PubSub, LiveView transport, and signed cookie sessions are configured.
- Tailwind v4, DaisyUI defaults, core inputs, layouts, SQL Sandbox support, and generated page/error tests exist. Reuse them; add no UI framework. README is boilerplate.
- Git contains starter and guideline/lockfile commits. Preserve existing work. Local tools are Elixir 1.20.1 / OTP 29 and a PostgreSQL 18 client; the database server version remains unverified. The local test-queue resolver reports this repository is not enrolled.
- Baseline `mix precommit` passed during planning: five starter tests, with no tracked application changes. This verifies the existing test database connection, not the future chat behavior.

## Decisions and assumptions

### Persistence, identity, and session

Use `App.Chat` for identity creation/reuse, default-room lookup, user/history queries, message creation, validation, and persisted-change notifications. Add `App.Chat.User`, `App.Chat.Room`, and `App.Chat.Message`. History and message-creation operations take an explicit room.

All three tables use server-generated UUIDv7 primary keys stored as Postgres `uuid`; foreign keys also use `uuid`. Use the installed Ecto support (`@primary_key {:id, Ecto.UUID, autogenerate: [version: 7]}`) on each schema, with matching UUID association/migration types. No extra UUID package or Postgres UUID-generation extension is needed. [Ecto UUID documentation](https://ecto.hexdocs.pm/Ecto.UUID.html)

| Table | Required columns and constraints |
| --- | --- |
| `users` | `id` UUIDv7 primary key; `name` text; `normalized_name` text with a unique index; UTC `inserted_at` and `updated_at`. |
| `rooms` | `id` UUIDv7 primary key; `name` text; `slug` text with a unique index; UTC `inserted_at` and `updated_at`. |
| `messages` | `id` UUIDv7 primary key; `user_id` UUID foreign key to users; `room_id` UUID foreign key to rooms; `body` text; UTC `inserted_at`. No `updated_at` because editing is out of scope. |

All listed columns are non-null. Add a composite index on `messages(room_id, id)` for complete, ordered history within a room. Do not persist online status or add a room-membership table.

- Users have a trimmed display `name` and server-derived `normalized_name`. Match with `String.trim/1` then `String.downcase/1`; internal whitespace and accents remain significant. Preserve the first stored spelling. Reject whitespace-only names.
- Put a non-null unique index on `users.normalized_name` in Postgres. Look up the normalized name, reuse the persisted user if found, otherwise insert. Do not accept a normalized name from the browser. Concurrent first joins for an equivalent name are outside the supported assumption: no automatic conflict recovery or dedicated join-race tests. Keep the database constraint and ordinary changeset error handling so a conflict cannot create duplicate identities. See `ASSUMPTIONS.md`.
- **Entering an existing name selects that identity; anyone can do so without authentication.** Store the selected user ID in the signed Phoenix session and resolve it against the database on mount. Missing or invalid identity returns the join experience.
- A CSRF-protected `POST /join` controller action performs the authoritative create/reuse operation, writes the cookie session, and redirects to `/`. The LiveView join form validates inline and uses `phx-trigger-action` for that HTTP handoff. The controller also validates direct submissions and returns useful inline errors. A LiveView socket assign alone cannot preserve identity across refreshes.
- Idempotently seed one room named `General` with stable slug `general`; rerunning seeds must reuse its UUID. `/` always resolves that room server-side. Document seeding in setup, and provide the same room through test fixtures. Do not create rooms on LiveView mount or add room switching/management UI. The schema permits additional rooms, including isolation fixtures, without exposing them in the UI.
- Derive `user_id` from the session-resolved user and `room_id` from the server-selected room held in the LiveView. Accept only message content from the form; never cast sender, room, ID, or timestamp from submitted parameters. Reject whitespace-only bodies, preserve internal newlines, and render escaped text with readable UTC timestamps.

`ASSUMPTIONS.md` records join concurrency, name reuse, identity selection without authentication, and **we do not care about sub-millisecond accuracy for chat**. Also assume shared browser-session identity across tabs and that refresh starts at the bottom; add these details there during implementation. Before joining, show the roster and join form; load history after joining.

### Ordered updates: append with a full-reload fallback

Streams control rendering, not database/client convergence. The [streams introduction](https://fly.io/phoenix-files/phoenix-dev-blog-streams/) explains their memory benefit; the [chat tutorial](https://fly.io/phoenix-files/building-a-chat-app-with-liveview-streams/) demonstrates incremental messages and older-history loading.

| Approach | Benefit | Cost and correctness obligations |
| --- | --- | --- |
| Persist, broadcast `messages_changed`, reload all history ordered by ID | One authoritative query handles initial history, late commits, repeated notifications, and reconnects. | Every notification causes a full query and render per joined connection; work grows with history and participant count. |
| Broadcast individual messages and insert them incrementally into streams | Smaller queries and patches per new message. | Must locate each message's canonical position, deduplicate it, handle lower IDs arriving later, and reconcile loading/reconnect races. Appending in PubSub arrival order is incorrect. |
| Append larger IDs; reload for older or repeated IDs | In-order messages need only a stream append; the ordered query resolves everything else. | Keep the largest displayed ID. Out-of-order and duplicate events still incur a full reload/reset. |

**Choose the append-with-reload-fallback approach**, with stable message DOM IDs and one `last_message_id` assign:

1. On mount/reconnect, load all history for the selected room in ascending ID order into the stream. Set `last_message_id` to that room's largest loaded ID, or `nil` for an empty history.
2. Broadcast `{:message_created, message}` after persistence on that room's topic, with the sender preloaded. Ignore events whose `room_id` differs from the selected room before changing the stream or `last_message_id`.
3. If history is empty or the incoming ID is strictly greater than `last_message_id`, append with `stream_insert` and advance that assign.
4. Otherwise, reload **all** history for the selected room, replace the stream with `stream(..., reset: true)`, and recompute `last_message_id` from the result. This handles both late smaller IDs and repeated events without a separate ID set or positional insertion logic.

Compare canonical UUID values in the same order as Postgres. The largest displayed ID is only an append decision, never a database query watermark: `WHERE id > last_message_id` could miss a smaller ID committed later. `stream_insert` does not automatically sort or reposition existing items (confirmed in the installed LiveView source).

Query `WHERE messages.room_id = selected_room.id ORDER BY messages.id ASC`, preload senders, and apply no limit. Generation order, commit order, timestamps, and PubSub delivery order are not ordering guarantees. If B commits before smaller ID A, the subsequent reload places A before B. Clients in the same room may briefly have different subsets while notifications are in flight; their histories converge after processing them.

Broadcast only after a successful database write has committed, outside any transaction containing it. Include the sending LiveView in notifications and use the same append-or-reload handler there, without a separate optimistic append. Repeated notifications trigger a reset rather than duplicate display. PubSub is not durable storage: a fresh mount/reconnect always reloads Postgres history.

### Mount and presence

Use one `AppWeb.ChatLive` at `/` and one supervised `AppWeb.Presence` after PubSub. No room process, separate browser Channel, or authentication system is needed.

Use a global user-change topic and room-specific message/presence topics, keyed by the stable room slug. On **connected mount**, subscribe using the configured `general` slug **before querying initial state**, then resolve the room and session identity, track the joined LiveView PID under its user UUID on that room's Presence topic, and load the roster/presence snapshot and joined user's room history. Events received while queries run remain queued: apply the append-or-reload rule to messages, including events already represented in the initial snapshot. Roster events trigger fresh reads. Unjoined visitors ignore message events. Disconnected rendering neither subscribes nor tracks.

Build the roster from **every persisted user**, sorted by normalized name and ID. Overlay online status from the displayed room's Presence topic: at least one metadata entry means Online. On `users_changed` or `presence_diff`, read the current roster/presence state and reset its stream. Never interpret one connection's leave as the whole user becoming offline. Visitors subscribe and see changes but are not tracked. Presence monitors the LiveView processes; cleanup must not depend on a browser unload event or `terminate/2`. Unexpected network loss becomes offline after disconnect detection, not instantaneously. [Presence documentation](https://phoenix.hexdocs.pm/Phoenix.Presence.html)

### History and scrolling: compare before choosing

| Method | Benefit | Cost |
| --- | --- | --- |
| Load all history | Meets the complete-history requirement directly and shares the ordered reload path. | Initial rendering, DOM size, and each reset grow with the conversation. |
| Infinite scroll with streams | Loads older messages on demand and can bound rendered content. | Needs UUID keyset cursors, page boundaries, overlap handling, late-insert reconciliation, and scroll anchoring; the initial page is only partial history. |

**Choose all history for the displayed room with no hidden latest-50 cutoff or stream limit.** Infinite scrolling is not part of this implementation. In-order events append one message; initial loads and fallback resets still grow with history. Bursts with out-of-order IDs or repeated notifications can cause frequent resets, with the same worst-case costs as full reloads on every event. Explain this deliberate tradeoff in the README.

Use a small hook in `assets/js/` to start at the bottom when history first mounts. Before a message patch, record whether the reader is near the bottom plus the first visible message ID and its viewport offset. After either an append or a reset, follow new messages only if already near the bottom; otherwise preserve the visible anchor, including when a late lower ID is inserted above it. The hook controls scrolling, while LiveView continues to own the streamed children.

## Implementation slices

### 1. Establish durable identities, rooms, and messages

**Deliver:** A small persistence API with normalized-name identity reuse, a seeded default room, and canonically ordered history scoped to a room.

**Work:** Generate migrations with `mix ecto.gen.migration`; add the three schemas, UUID foreign keys, constraints/indexes, context operations, and committed-change broadcasts. Use Ecto's UUIDv7 autogeneration for every primary key and ensure the declared dependency range includes the API used. Add idempotent default-room seeding.

**Verify:** Create a user, then join sequentially with equivalent trimmed/case-varied names; assert one row and the same returned identity. Include blank-name rejection. This catches broken normalization, identity reuse, and validation without testing concurrent joins. In the persistence flow, verify UUIDv7 IDs for a user, room, and message; seed twice and assert the default room retains its ID. Store messages in two rooms and verify each history includes only its own rows in ascending ID order despite reversed insertion order. This catches accidental UUIDv4/integer IDs, duplicate default rooms, broken associations, room leakage, and implicit database ordering.

**Complete when:** Migrations and seeds work on an empty database, targeted persistence tests pass, and failed writes produce no persisted-change notification.

### 2. Join, retain identity, and show the live roster

**Deliver:** A visitor can watch all users, join by name, refresh with the same identity, and see correct connection status.

**Work:** Replace the welcome route with `ChatLive`; add the join controller/route, signed-session handoff, Presence supervision, subscriptions before initial reads, and a roster stream. Use `<Layouts.app>`, `to_form`, and core inputs. Put the join form in the main area and explicit Online/Offline labels in the left sidebar; show errors inline without success flashes.

**Verify:** Follow an actual join form through its HTTP session handoff and refresh, including existing-name reuse and blank input. This catches identity stored only in socket state and missing server validation. In a separate multi-connection scenario, observe from an unjoined LiveView, create/join a user, open two LiveViews as that user, close one, and abruptly terminate the last. Assert all persisted users remain listed, the first closure stays Online, the last becomes Offline, and the visitor is never present. This catches incomplete rosters, missing broadcasts, and connection/user confusion.

**Complete when:** Independent observers see roster changes and presence cleanup, and session-backed refresh restores the selected identity.

### 3. Send and converge on the complete ordered conversation

**Deliver:** Joined users see all persisted messages with sender/timestamp and send multiline messages to every participant.

**Work:** Add streamed room history, a multiline composer, sender/room enforcement, and blank-message feedback. Track `last_message_id` for the displayed room, append strictly larger incoming IDs, and reset from that room's complete ordered history otherwise. Deliver persisted-message events with senders preloaded to joined LiveViews in that room, including the sender. Clear the composer only after persistence succeeds.

**Verify:** Use two independent LiveViews, starting empty, then a fresh mount with more than 50 persisted messages. Send through the UI and compare ordered message DOM IDs to the selected room's database history: cover larger-ID appends, a lower UUIDv7 committed after a higher one, repeated events through real PubSub, and a subsequent larger-ID message after a reset. Assert each persisted message appears once and messages/events from a second room never appear or disturb ordering. This catches truncation, arrival-order appends, stale append state, duplicates, and room leakage. Include blank submissions, an unjoined send attempt, and forged sender/room parameters; these must not create unauthorized/blank rows or override the selected user/room. Pause connected mount after its history SELECT has captured a result, commit a message through an independent writer, then resume: the message must appear through its queued event even though absent from the initial snapshot. Separately cover an event already represented in the snapshot. This catches missed updates and duplicate initial/live overlap without mocking the query or PubSub.

**Complete when:** All connected participants and a fresh mount converge to the same complete ID-ordered history, with validation failures leaving history unchanged.

### 4. Finish scrolling, recovery, and submission

**Deliver:** A usable minimal room and a reproducible handoff.

**Work:** Add the scroll hook and minimal responsive layout. Replace the README with dependencies, Postgres configuration/setup, running the app, test commands, and a concise architecture explanation covering ordering, Presence, and the append-with-full-reload-fallback tradeoff. Complete `ASSUMPTIONS.md` from the decisions above; keep `ROADMAP.md` as the sole execution plan.

**Verify:** Terminate and remount a LiveView with the same signed session after another user persisted a message while it was disconnected; verify the session identity, complete history, subsequent message delivery, and Presence registration recover. This catches reliance on transient PubSub state or stale append state. In a real browser, also exercise a transport disconnect/reconnect and check initial bottom position, following while at bottom, and retaining an older visible message during both appends and fallback resets with late-ID insertion. LiveView tests do not execute the scrolling JavaScript. Also check multiline input, readable validation, and sidebar usability at narrow widths. Run the full precommit gate and follow the README from a clean test database.

**Complete when:** Recovery and browser checks pass, setup instructions reproduce the app, the full gate passes, and the repository contains the application, README, assumptions, and truthful incremental commits.

## Execution rules and remaining unknowns

- Make real incremental commits as slices pass verification, including their meaningful tests. Do not fabricate history or commit unrelated work.
- Test context, HTTP-session, and multi-LiveView behavior with real database/PubSub/Presence and stable DOM IDs. Avoid callback/helper tests, snapshots, styling assertions, repetitive permutations, and coverage/test-count targets.
- Run shared-topic tests serially. The message-during-load scenario needs an independent writer and cleanup of committed fixtures; join-race test infrastructure is out of scope. Use `start_supervised!` for workers and messages/process monitors instead of arbitrary sleeps.
- Recheck enrollment before implementation checks with `python3 ~/.codex/tools/db-test-slot/project.py --resolve`. If still unenrolled, use targeted `mix test` and final `mix precommit`; if enrolled, use the required queued equivalents. Keep one full-gate owner.
- Verify the Postgres server version and development database setup at slice 1; recheck test connectivity then. No product decision is blocked on this; UUIDv7 is generated by Ecto. Record verified setup requirements in the README.
- The authorized room scope is a multi-room-capable schema with one seeded room exposed in the UI. Exclude room switching/management, memberships, accounts/passwords, private chat, typing indicators, attachments, editing/deletion, receipts, notifications, search, custom sequencing, room GenServer, deployment work, and speculative scaling.


## Execution record

Roadmap revision: approved UUIDv7/rooms/append-or-reload design, with review clarifications above.
Baseline: `e5eeb0e`, clean checkout; branch `codex/chat-roadmap`.
Full-gate owner: primary agent. Local queue: not enrolled. PostgreSQL server: 17.6.

| Slice | Status | Evidence |
| --- | --- | --- |
| 1 — Persistence | done | Context tests passed (2); full precommit passed (7 tests); new development database migrated and seed rerun successfully. |
| 2 — Identity and roster | done | HTTP/session and multi-connection tests passed (2); precommit passed (8 total); assets built; browser blank-name, join, online status, and refresh checks passed. |
| 3 — Ordered conversation | done | Three message/mount scenarios passed; precommit passed (11 total); browser multiline send persisted and displayed with sender/time. |
| 4 — Scrolling and handoff | planned | Depends on slice 3. |

active_slice: none — slice 3 verified.
next_candidate: 4 — Scrolling and handoff.

Slice 1 preplan: implement the three schemas, generated migration, context, seed, and persistence scenarios described above. No UI or Presence changes in this slice. Use the installed Ecto UUIDv7 API and explicit UTC timestamp types. Verify with focused context tests, migration/seed checks, and `mix precommit`. Schema additions are additive; do not reset existing development data. Changed files and results will be recorded at closure.

Last safe checkpoint: slice 3 verified. Dedicated `ahead_chat_dev` / `ahead_chat_test` databases avoid an existing unrelated `app_test.users` table; that database was not changed.
Blockers: none.
Next action: implement scroll anchoring, verify recovery in tests and the browser, and finish setup/architecture documentation.

Slice 2 preplan: build one ChatLive, the POST join handoff, Presence supervision, and a streamed roster using existing form components. No message composer/history or scroll hook yet. Verify a real HTTP session round trip, blank input, visitor roster updates, and two tracked connections with final abrupt termination; then run precommit and manually open the page. Baseline: `443775d`. Changes are reversible web-layer additions; preserve all persisted users.

Slice 2 result: added ChatLive, join controller, Presence, router and minimal layout; replaced welcome-page test with two integration scenarios. Browser checks used a dedicated port 4001 server, now stopped; the existing port 4000 server was left alone. Explicit PORT support was added for local previews. No blockers or waivers.

Slice 3 preplan: add message history/composer and append-or-reload handling to ChatLive. Keep scroll behavior for slice 4. Verify independent views, >50 rows, lower/repeated IDs, spoofed attributes, room isolation, and a real committed write after the initial SELECT using a test-only telemetry barrier. Baseline: `0dcf2ca`; existing data is preserved. Run focused tests and precommit, then smoke-test sending in the browser.

Slice 3 result: ChatLive now renders complete history and accepts messages with inline validation; in-order notifications append and lower/repeated IDs reset to database order. Added two message-flow scenarios and one mount-window scenario. The latter uses two real database connections and synchronous query telemetry to prove the new message was absent from the captured snapshot; a second mount verifies snapshot/event overlap. Only that test opts out of transaction rollback and explicitly cleans up its committed fixtures. No production test hooks or mocked delivery. All checks passed; no blockers or waivers.
