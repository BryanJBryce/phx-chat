# Chat

A single shared chat room built with Phoenix LiveView, Ecto, and Postgres. Visitors see every persisted user and their live Online/Offline status. Enter a name to join, read the entire conversation, and send multiline messages. Names select identities without passwords; entering an existing name joins as that person.

## Run locally

Install Elixir 1.17 or later with a compatible Erlang/OTP, Git, and PostgreSQL. This checkout was verified with Elixir 1.20.1, OTP 29, and PostgreSQL 17.6. Dependencies are locked in `mix.lock` (Phoenix 1.8, LiveView 1.2, Ecto 3.14). Ecto generates UUIDv7 IDs; no database extension is needed. Mix downloads the Tailwind/esbuild binaries, so Node/npm are not required.

Start PostgreSQL and make a local role available with permission to create databases. The development and test configs default to `postgres` / `postgres` at `localhost:5432`. For a fresh local PostgreSQL installation that does not have that role, connect as its administrator and run:

```sql
CREATE ROLE postgres WITH LOGIN CREATEDB PASSWORD 'postgres';
```

If the role already exists, use its credentials in `config/dev.exs` and `config/test.exs`; do not recreate it. The app uses dedicated `ahead_chat_dev` and `ahead_chat_test` databases. Then, from this repository:

```sh
mix local.hex --if-missing
mix local.rebar --if-missing
mix setup
mix phx.server
```

Open [localhost:4000](http://localhost:4000). Use `PORT=4001 mix phx.server` if that port is occupied. `mix setup` fetches dependencies, creates/migrates the development database, seeds the General room, and builds assets. Seeding is idempotent and keeps the same room ID; it does not erase history. After pulling changes, use `mix ecto.migrate` and `mix run priv/repo/seeds.exs` as needed.

## Verify

```sh
mix test
mix precommit
mix assets.build
mix credo --strict
```

`mix test` creates/migrates the test database automatically. Tests provide their own rooms and users; do not seed the test database. `mix precommit` compiles with warnings treated as errors, removes unused lock entries, formats, and runs the suite. Credo also runs the repository's configured ExSlop checks.

The suite uses real Postgres, PubSub, and Presence. Shared-topic tests run serially. Most tests roll back through SQL Sandbox; the mount-window scenario deliberately uses independently committed connections and removes only its own fixtures. Use a dedicated test database without other application processes writing to it. To verify from a new test database without resetting existing data, choose an unused suffix, for example `MIX_TEST_PARTITION=_fresh_check mix test`.

The focused scenarios protect these failures:

- Normalization/reuse and blank-name rejection: avoids duplicate sequential identities and invalid roster entries.
- Persistence, server-derived sender/room, UUIDv7, and scoped ordering: prevents impersonation through form attributes and cross-room history leakage.
- The HTTP join/session round trip and refresh: catches an identity stored only in a socket assign.
- Visitor roster updates and two connections for one identity, including abrupt termination: catches premature Offline status and stale Presence.
- Independent message views, more than 50 rows, late IDs, and repeated events: catches missed delivery, truncation, inconsistent ordering, and duplicates.
- A write after the initial SELECT has captured its result, plus snapshot/event overlap: catches subscribing too late and displaying the same persisted message twice.
- Remount after missed messages: catches reliance on transient events or a stale maximum-ID cursor for recovery.

LiveView tests do not execute JavaScript or simulate an actual network reconnect. Browser verification covers multiline input/errors, initial bottom position, following messages only when at the bottom, preserving a visible message through appends and resets, transport reconnect, and a narrow viewport. Execution evidence is in [ROADMAP.md](ROADMAP.md).

## Architecture

`App.Chat` owns user/room/message persistence and successful-write notifications. The three schemas use UUIDv7 primary keys and UUID foreign keys. Postgres enforces unique normalized names, unique room slugs, and message references. `messages(room_id, id)` indexes the full ordered room query. The schema supports other rooms, while `/` always resolves the seeded `general` room server-side.

`AppWeb.ChatLive` renders the roster, join form, history, and composer using LiveView streams. Connected mounts subscribe before reading initial state. A CSRF-protected `POST /join` validates the name and writes the user ID into the signed Phoenix cookie session; each mount resolves that ID from Postgres. Message forms supply only the body. The LiveView supplies the selected user and room. Invalid input appears beside the form.

`AppWeb.Presence` tracks only joined, connected LiveView processes, keyed by user UUID on the room's Presence topic. A user is Online while at least one metadata entry remains. Visitors subscribe but are not tracked. On each roster or presence notification, the view reads all persisted users and overlays current Presence; it never saves an online flag or treats one tab's departure as the whole user leaving. Network failures become Offline after the transport detects the loss and terminates the connection.

### Ordering and the reload tradeoff

Ascending message UUID is the canonical order for initial history and updates. UUID strings are in canonical lowercase form, so their lexical order agrees with Postgres UUID order. Generation, commit, timestamp, and PubSub arrival order are not assumed to match. Sub-millisecond real-world send order does not matter.

On mount/reconnect, the view loads **all** room messages ordered by ID, preloads senders, and sets its largest displayed ID. A successful standalone insert broadcasts the persisted message, including to its sender. A strictly larger ID appends to the stream. A smaller or repeated ID reloads all ordered history and resets the stream, so late commits and duplicates converge without tracking an ID set. The maximum ID is never used as a database query watermark. Foreign-room events are ignored. Persistence calls must remain outside any enclosing transaction so broadcasts occur only after commit.

Reloading on every event would be simpler but repeat the full query and render for ordinary in-order messages. Maintaining arbitrary sorted stream insertions would avoid reloads but require more reconciliation state. This middle ground keeps normal patches small and uses Postgres to settle the uncommon cases. Initial loads and fallback resets still cost proportional to history, and frequent out-of-order events can cause repeated full reloads. Streams avoid retaining the whole message list in each LiveView process; they do not bound the browser DOM, database work, or reset payloads. There is no hidden latest-50 limit, pagination, or infinite scrolling.

PubSub is transient, not a durable event log; fresh mounts recover from persisted history. A small JavaScript hook starts at the bottom, follows updates only when already near it, and otherwise restores the first visible message and its offset after an append or reset. It captures/restores at LiveSocket's DOM patch boundaries: an element's `beforeUpdate` runs too late to capture rows removed by a stream reset. LiveView owns the message DOM; the hook only adjusts scrolling.

See [ASSUMPTIONS.md](ASSUMPTIONS.md) for identity, concurrency, recovery, and scope assumptions. No separate browser Channel, custom room GenServer, account system, or room management UI is included.
