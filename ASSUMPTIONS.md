# Assumptions

- First-time joins using the same normalized name are assumed not to occur concurrently. Automatic recovery and dedicated tests for join races are out of scope. Postgres still enforces normalized-name uniqueness; an unexpected conflict can return an ordinary validation error, and the visitor can retry.
- Names are trimmed and matched case-insensitively. Joining creates a user when the normalized name is new and otherwise reuses the existing user, preserving the original display spelling.
- There is no authentication. Entering an existing name selects that identity; it does not prove ownership.
- Users, rooms, and messages all use server-generated UUIDv7 primary keys. Message foreign keys to users and rooms are also UUIDs.
- The database supports multiple rooms, but the UI initially exposes only the seeded `General` room (`general` slug). There is no room selection, management, or membership model. Messages and live updates are scoped to the selected room; its roster still lists every persisted user, with Online meaning at least one joined connection in that room.
- We do not care about sub-millisecond accuracy for chat. Ascending UUIDv7 message ID is the canonical display order, not exact real-world send order.
