import Foundation

public struct ImportedCredentials: Equatable, Sendable {
    public let url: String?
    public let cookie: String
    public let userAgent: String?
    public let referer: String?
    public let authorizationToken: String?

    public init(
        url: String? = nil,
        cookie: String = "",
        userAgent: String? = nil,
        referer: String? = nil,
        authorizationToken: String? = nil
    ) {
        self.url = url
        self.cookie = cookie
        self.userAgent = userAgent
        self.referer = referer
        self.authorizationToken = authorizationToken
    }

    public var isEmpty: Bool {
        cookie.isEmpty && (authorizationToken ?? "").isEmpty && (userAgent ?? "").isEmpty
    }
}

/// Parses credentials pasted from Chrome/Safari DevTools (`Copy as cURL`), raw HTTP headers,
/// plain `Cookie` headers, or Copymanga `Token ...` strings.
public enum CurlImportParser {
    public static func parse(_ rawInput: String) -> ImportedCredentials {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ImportedCredentials() }

        let loweredPrefix = trimmed.lowercased()
        if loweredPrefix.hasPrefix("curl ") || loweredPrefix.hasPrefix("curl\t") || loweredPrefix.hasPrefix("curl\n") {
            return parseCurlCommand(trimmed)
        }

        // Plain Token / Bearer line
        if !trimmed.contains("\n") {
            if let token = extractTokenValue(from: trimmed), !trimmed.contains("=") {
                return ImportedCredentials(authorizationToken: token)
            }
        }

        // Raw HTTP headers block (contains header keys like Cookie:, User-Agent:, Authorization:)
        if looksLikeHeaderLines(trimmed) {
            return parseRawHeaders(trimmed)
        }

        // Plain cookie string (optionally prefixed with "Cookie:")
        let normalizedCookie = normalizeCookieValue(trimmed)
        return ImportedCredentials(cookie: normalizedCookie)
    }

    // MARK: - cURL Parser

    private static func parseCurlCommand(_ command: String) -> ImportedCredentials {
        // Normalize shell line continuations (`\\\n` and `^\n` from cmd)
        let unfolded = command
            .replacingOccurrences(of: "\\\r\n", with: " ")
            .replacingOccurrences(of: "\\\n", with: " ")
            .replacingOccurrences(of: "^\r\n", with: " ")
            .replacingOccurrences(of: "^\n", with: " ")

        let tokens = tokenizeShell(unfolded)
        var url: String?
        var cookieParts: [String] = []
        var userAgent: String?
        var referer: String?
        var authToken: String?

        var i = 0
        while i < tokens.count {
            let tok = tokens[i]
            if i == 0 && tok.lowercased() == "curl" {
                i += 1
                continue
            }

            if tok == "-H" || tok == "--header" {
                if i + 1 < tokens.count {
                    applyHeaderLine(
                        tokens[i + 1],
                        cookieParts: &cookieParts,
                        userAgent: &userAgent,
                        referer: &referer,
                        authToken: &authToken
                    )
                    i += 2
                    continue
                }
            } else if tok == "-b" || tok == "--cookie" {
                if i + 1 < tokens.count {
                    let c = normalizeCookieValue(tokens[i + 1])
                    if !c.isEmpty { cookieParts.append(c) }
                    i += 2
                    continue
                }
            } else if tok == "-A" || tok == "--user-agent" {
                if i + 1 < tokens.count {
                    let ua = tokens[i + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                    if !ua.isEmpty { userAgent = ua }
                    i += 2
                    continue
                }
            } else if tok == "-e" || tok == "--referer" {
                if i + 1 < tokens.count {
                    let ref = tokens[i + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                    if !ref.isEmpty { referer = ref }
                    i += 2
                    continue
                }
            } else if tok.hasPrefix("http://") || tok.hasPrefix("https://") {
                if url == nil { url = tok }
            }
            i += 1
        }

        let mergedCookie = mergeCookieStrings(cookieParts)
        return ImportedCredentials(
            url: url,
            cookie: mergedCookie,
            userAgent: userAgent,
            referer: referer,
            authorizationToken: authToken
        )
    }

    private static func parseRawHeaders(_ text: String) -> ImportedCredentials {
        var cookieParts: [String] = []
        var userAgent: String?
        var referer: String?
        var authToken: String?
        var url: String?

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://"), url == nil {
                url = trimmed
                continue
            }
            applyHeaderLine(
                trimmed,
                cookieParts: &cookieParts,
                userAgent: &userAgent,
                referer: &referer,
                authToken: &authToken
            )
        }

        return ImportedCredentials(
            url: url,
            cookie: mergeCookieStrings(cookieParts),
            userAgent: userAgent,
            referer: referer,
            authorizationToken: authToken
        )
    }

    private static func applyHeaderLine(
        _ line: String,
        cookieParts: inout [String],
        userAgent: inout String?,
        referer: inout String?,
        authToken: inout String?
    ) {
        guard let colon = line.firstIndex(of: ":") else { return }
        let name = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }

        switch name {
        case "cookie":
            let normalized = normalizeCookieValue(value)
            if !normalized.isEmpty { cookieParts.append(normalized) }
        case "user-agent":
            userAgent = value
        case "referer", "referrer":
            referer = value
        case "authorization":
            if let token = extractTokenValue(from: value) {
                authToken = token
            } else {
                authToken = value
            }
        default:
            break
        }
    }

    private static func looksLikeHeaderLines(_ text: String) -> Bool {
        let lower = text.lowercased()
        let markers = ["user-agent:", "authorization:", "referer:", "referrer:"]
        if markers.contains(where: { lower.contains($0) }) { return true }
        if text.contains("\n") && lower.contains("cookie:") { return true }
        return false
    }

    private static func extractTokenValue(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("token ") {
            let val = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
            return val.isEmpty ? nil : val
        }
        if lower.hasPrefix("bearer ") {
            let val = String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
            return val.isEmpty ? nil : val
        }
        return nil
    }

    private static func normalizeCookieValue(_ raw: String) -> String {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.lowercased().hasPrefix("cookie:") {
            cleaned = String(cleaned.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return cleaned
    }

    private static func mergeCookieStrings(_ parts: [String]) -> String {
        var result = ""
        for part in parts {
            let pairs = part.split(separator: ";").compactMap { segment -> (String, String)? in
                let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let eq = trimmed.firstIndex(of: "=") else { return nil }
                let key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespacesAndNewlines)
                let val = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else { return nil }
                return (key, val)
            }
            result = HTTPRuntime.mergeCookieHeader(existing: result, updating: pairs)
        }
        return result
    }

    private static func tokenizeShell(_ input: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character? = nil
        var escaped = false
        let chars = Array(input)
        var i = 0

        while i < chars.count {
            let ch = chars[i]
            if escaped {
                current.append(ch)
                escaped = false
                i += 1
                continue
            }

            if let activeQuote = quote {
                if activeQuote == "\"" && ch == "\\" {
                    escaped = true
                } else if ch == activeQuote {
                    quote = nil
                } else {
                    current.append(ch)
                }
                i += 1
                continue
            }

            if ch == "$" && i + 1 < chars.count && chars[i + 1] == "'" {
                quote = "'"
                i += 2
                continue
            }
            if ch == "'" || ch == "\"" {
                quote = ch
                i += 1
                continue
            }
            if ch == "\\" {
                escaped = true
                i += 1
                continue
            }
            if ch.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                i += 1
                continue
            }
            current.append(ch)
            i += 1
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }
}
