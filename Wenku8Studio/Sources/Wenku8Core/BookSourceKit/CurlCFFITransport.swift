import Foundation

public struct CurlCFFIEnvironmentStatus: Equatable, Sendable {
    public let isAvailable: Bool
    public let pythonPath: String?
    public let curlCFFIVersion: String?
    public let message: String

    public init(isAvailable: Bool, pythonPath: String? = nil, curlCFFIVersion: String? = nil, message: String) {
        self.isAvailable = isAvailable
        self.pythonPath = pythonPath
        self.curlCFFIVersion = curlCFFIVersion
        self.message = message
    }
}

/// Optional out-of-process HTTP transport that delegates requests to a local Python `curl_cffi`
/// installation so imported browser `cf_clearance` cookies match Chrome/Safari TLS fingerprints.
public final class CurlCFFITransport: HTTPTransport, Sendable {
    public let pythonExecutable: String
    public let impersonateProfile: String

    private static let bridgeScript = """
    import sys, json, base64
    from curl_cffi import requests

    payload = json.loads(sys.stdin.read())
    url = payload["url"]
    method = payload.get("method", "GET")
    headers = payload.get("headers", {})
    body_b64 = payload.get("body_b64")
    body = base64.b64decode(body_b64) if body_b64 else None
    timeout = float(payload.get("timeout", 15))
    impersonate = payload.get("impersonate", "chrome131")

    resp = requests.request(
        method,
        url,
        headers=headers,
        data=body,
        timeout=timeout,
        impersonate=impersonate,
        allow_redirects=True,
    )
    set_cookies = []
    try:
        for k, v in resp.cookies.items():
            set_cookies.append([str(k), str(v)])
    except Exception:
        pass
    out = {
        "status": int(resp.status_code),
        "url": str(resp.url),
        "headers": {str(k): str(v) for k, v in resp.headers.items()},
        "body_b64": base64.b64encode(resp.content).decode("ascii"),
        "set_cookies": set_cookies,
    }
    sys.stdout.write(json.dumps(out))
    """

    public init(pythonExecutable: String, impersonateProfile: String = "chrome131") {
        self.pythonExecutable = pythonExecutable
        self.impersonateProfile = impersonateProfile
    }

    public static func inferImpersonateProfile(fromUserAgent ua: String) -> String {
        let lower = ua.lowercased()
        if lower.contains("safari") && !lower.contains("chrome") && !lower.contains("crios") {
            return "safari17_0"
        }
        return "chrome131"
    }

    public static func candidatePythonPaths(preferredPythonPath: String = "") -> [String] {
        var candidates: [String] = []
        let trimmed = preferredPythonPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            candidates.append(trimmed)
        }
        let cwd = FileManager.default.currentDirectoryPath
        candidates.append("\(cwd)/.venv/bin/python")
        candidates.append("\(cwd)/.venv/bin/python3")
        candidates.append("/opt/homebrew/bin/python3")
        candidates.append("/usr/local/bin/python3")
        candidates.append("/usr/bin/python3")

        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    public static func detectEnvironment(preferredPythonPath: String = "") -> CurlCFFIEnvironmentStatus {
        let trimmed = preferredPythonPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let paths: [String] = trimmed.isEmpty
            ? candidatePythonPaths()
            : [trimmed]

        for path in paths {
            guard FileManager.default.isExecutableFile(atPath: path) else { continue }
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: path)
            proc.arguments = ["-c", "import curl_cffi; print(getattr(curl_cffi, '__version__', 'installed'))"]
            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe
            do {
                try proc.run()
                proc.waitUntilExit()
                if proc.terminationStatus == 0 {
                    let version = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "installed"
                    return CurlCFFIEnvironmentStatus(
                        isAvailable: true,
                        pythonPath: path,
                        curlCFFIVersion: version,
                        message: "已就绪：\(path)（curl_cffi \(version)）"
                    )
                }
            } catch {
                continue
            }
        }

        return CurlCFFIEnvironmentStatus(
            isAvailable: false,
            pythonPath: nil,
            curlCFFIVersion: nil,
            message: "未检测到安装 curl_cffi 的 Python，可执行 `pip3 install curl_cffi` 或指定自定义 Python 路径"
        )
    }

    public func send(_ request: HTTPTransportRequest) async throws -> HTTPTransportResponse {
        guard FileManager.default.isExecutableFile(atPath: pythonExecutable) else {
            throw SourceError.networkError("找不到 curl_cffi Python 可执行文件：\(pythonExecutable)")
        }

        var headers = request.extraHeaders
        headers["User-Agent"] = request.userAgent
        if headers["Accept-Language"] == nil {
            headers["Accept-Language"] = "zh-CN,zh;q=0.9,en;q=0.8"
        }
        if let referer = request.referer, !referer.isEmpty {
            headers["Referer"] = referer
        }
        if !request.cookie.isEmpty {
            headers["Cookie"] = request.cookie
        }

        var payload: [String: Any] = [
            "url": request.url.absoluteString,
            "method": request.method,
            "headers": headers,
            "timeout": request.timeout,
            "impersonate": Self.inferImpersonateProfile(fromUserAgent: request.userAgent)
        ]
        if let body = request.body {
            payload["body_b64"] = body.base64EncodedString()
        }

        let inputData = try JSONSerialization.data(withJSONObject: payload)
        let executablePath = self.pythonExecutable
        let script = Self.bridgeScript

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: executablePath)
                proc.arguments = ["-c", script]

                let inPipe = Pipe()
                let outPipe = Pipe()
                let errPipe = Pipe()
                proc.standardInput = inPipe
                proc.standardOutput = outPipe
                proc.standardError = errPipe

                do {
                    try proc.run()
                    inPipe.fileHandleForWriting.write(inputData)
                    try? inPipe.fileHandleForWriting.close()

                    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    proc.waitUntilExit()

                    guard proc.terminationStatus == 0 else {
                        let errMsg = String(data: errData, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "未知子进程错误"
                        continuation.resume(throwing: SourceError.networkError("curl_cffi 桥接执行失败：\(errMsg)"))
                        return
                    }

                    guard let obj = try JSONSerialization.jsonObject(with: outData) as? [String: Any],
                          let status = obj["status"] as? Int,
                          let b64 = obj["body_b64"] as? String,
                          let data = Data(base64Encoded: b64) else {
                        continuation.resume(throwing: SourceError.parseError("curl_cffi 桥接返回格式无效"))
                        return
                    }

                    let finalURL = (obj["url"] as? String) ?? request.url.absoluteString
                    let respHeaders = (obj["headers"] as? [String: String]) ?? [:]
                    let rawCookies = (obj["set_cookies"] as? [[String]]) ?? []
                    let pairs: [(String, String)] = rawCookies.compactMap { arr in
                        guard arr.count >= 2 else { return nil }
                        return (arr[0], arr[1])
                    }

                    continuation.resume(returning: HTTPTransportResponse(
                        statusCode: status,
                        data: data,
                        headers: respHeaders,
                        finalURL: finalURL,
                        setCookiePairs: pairs
                    ))
                } catch {
                    continuation.resume(throwing: SourceError.networkError("无法启动 curl_cffi 桥接：\(error.localizedDescription)"))
                }
            }
        }
    }
}
