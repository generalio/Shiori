# 0003: Local-First `LocalShelf` with Isolated Per-Source `CloudShelf` Sync

Status: accepted

`Wenku8`, `Bilinovel`, and `Copymanga` expose incompatible remote bookshelf semantics: `Wenku8` supports bidirectional 5-group cloud bookcases with `aid_bid` slots and capacity quotas, `Copymanga` uses Bearer `Token`-authenticated user subscriptions, and `Bilinovel` primarily relies on web session cookies without a stable structured bookcase API.

We decided to treat `LocalShelf` (keyed by `ScopedWorkID` and source+work-scoped `Chapter` IDs) as the unified single source of truth across all `BookSource`s, with optional per-source `CloudShelf` adapters that merge remote state independently per source without cross-source replication, rather than forcing all plugins into Wenku8's `aid_bid` group schema or removing cloud sync altogether. This prevents one source's expired session or schema limitations from blocking unified library management and reading progress tracking.
