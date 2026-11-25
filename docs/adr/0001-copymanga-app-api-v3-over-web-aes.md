# 0001: Use Copymanga App API v3 as Primary Transport over Web AES Scraping

Status: accepted

Copymanga's web pages encrypt chapter payloads using AES-CBC with dynamically injected page keys (`jojo`/`dio`) and trigger web CDN limits aggressively, whereas its App API v3 (`/api/v3/comic2`, `/api/v3/comic/.../chapters`, `/api/v3/comic/.../chapter2`, `/api/v3/search/comic`) returns structured JSON directly, cleanly separates work groups (`default` vs `tankobon`), and allows anonymous catalog/chapter reads with optional `Authorization: Token` authentication for personal cloud shelves.

We decided to build `CopymangaPlugin` on top of App API v3 with configurable mirror domains and image resolution selection (e.g., `.c800x` vs `.c1500x`), rather than embedding a JS/WebKit AES decryption scraper as the primary path. Because newer Copymanga API mirrors occasionally enforce signed App headers (`x-auth-timestamp`, `x-auth-signature`), the plugin isolates request signing and mirror overrides behind its transport configuration so mirror/header updates stay localized without affecting domain models or UI views.
