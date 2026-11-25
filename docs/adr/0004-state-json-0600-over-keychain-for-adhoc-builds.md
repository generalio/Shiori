# 0004: Store `SourceAuthState` in `0600`-Restricted `state.json` Instead of macOS Keychain

Status: accepted

`Shiori.app` is built locally and distributed primarily with ad-hoc code signatures (`--sign -` / unsigned local Xcode builds). Storing `SourceAuthState` secrets (external-browser `Cookie`, `cf_clearance`, and Copymanga Bearer `Token`) inside macOS Keychain binds ACL trust to the designated code requirement of each build, causing repeated interactive Keychain permission dialogs on every app rebuild or update.

We decided to store per-source credentials inside `Application Support/Shiori/state.json` alongside existing app state while enforcing POSIX `0600` (owner read/write only) permissions, rather than using macOS Keychain. This keeps rebuilds and automated/headless verification friction-free while restricting local multi-user file access, and remains reversible later if signed/notarized Developer ID distribution is adopted.
