# Assumptions

- First-time joins using the same normalized name are assumed not to occur concurrently. Automatic recovery and dedicated tests for join races are out of scope. Postgres still enforces normalized-name uniqueness; an unexpected conflict can return an ordinary validation error, and the visitor can retry.
- Names are trimmed and matched case-insensitively. Joining creates a user when the normalized name is new and otherwise reuses the existing user, preserving the original display spelling.
- There is no authentication. Entering an existing name selects that identity; it does not prove ownership.
- Users, rooms, and messages all use server-generated UUIDv7 primary keys. Message foreign keys to users and rooms are also UUIDs.
- The database supports multiple rooms, but the UI initially exposes only the seeded `General` room (`general` slug). There is no room selection, management, or membership model. Messages and live updates are scoped to the selected room; its roster still lists every persisted user, with Online meaning at least one joined connection in that room.
- We do not care about sub-millisecond accuracy for chat. Ascending UUIDv7 message ID is the canonical display order, not exact real-world send order.
- Normalization is `String.trim/1` followed by `String.downcase/1`; internal whitespace and accents remain significant. Only the name is accepted from the visitor; normalized names are derived on the server.
- Browser tabs share the signed session cookie. Already connected tabs retain their current identity until remount; refreshing uses the cookie's latest selection. Missing, invalid, or deleted session identities return to the join form. No logout/account controls are included.
- Users and messages persist indefinitely. Message bodies are trimmed at the edges, preserve internal newlines, and display as escaped text. Timestamps are shown in UTC.
- Before joining, visitors see the roster and join form; conversation history loads after joining. Every room message is loaded, with no hidden count limit. Initial load and refresh start at the bottom; scrolling upward preserves the reader's position during live updates.
- PubSub notifications are transient. Reconnect reloads persisted state, including messages missed while disconnected. Unexpected disconnects become Offline after transport failure detection; instant network-loss detection is not promised.
- Chat writes are standalone database operations. If callers later wrap them in a transaction, notifications must move after the outer commit. Durable notification delivery, large-history optimization, and exact wall-clock send ordering are outside this small application.
