# 0002: External Python `curl_cffi` Bridge for Optional Cloudflare TLS Impersonation

Status: accepted

Embedded `WKWebView` inside an ad-hoc macOS app frequently fails interactive Cloudflare Turnstile verification, whereas the user's external browser passes normally. Even when the user imports `cf_clearance` and matching `User-Agent` from their external browser, Cloudflare binds `cf_clearance` to the browser's TLS fingerprint (JA3/JA4), causing macOS native `URLSession` requests to continue receiving 403 rejections.

We decided to support an external browser authentication handoff ("Open in System Browser" + `Copy as cURL` / Cookie+UA import) backed by an optional out-of-process local Python `curl_cffi` HTTP bridge for TLS-impersonated requests, rather than bundling a Python interpreter or `libcurl-impersonate` dynamic libraries inside `Shiori.app`. Keeping the runtime external preserves `Shiori.app`'s lightweight bundle footprint and ad-hoc code-signing pipeline while giving users on Cloudflare-gated sources a clean toggle and environment check, falling back to UA-aligned `URLSession` / `WKWebView` when unavailable.
