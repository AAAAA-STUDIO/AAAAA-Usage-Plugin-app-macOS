import AppKit
import CryptoKit
import Darwin
import Foundation
import Security

final class DeepSeekOAuth {
    private let platform = URL(string: "https://platform.deepseek.com")!
    private let redirectDelegate = NoRedirectDelegate()
    private lazy var session = URLSession(configuration: .ephemeral, delegate: redirectDelegate, delegateQueue: nil)

    func signIn() async throws {
        let verifier = try randomURLSafeString(byteCount: 32)
        let state = try randomURLSafeString(byteCount: 24)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8)))
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let listener = try makeLoopbackListener()
        defer { Darwin.close(listener.fd) }
        let redirectURI = "http://127.0.0.1:\(listener.port)/oauth/callback"

        let initPayload = try await post(
            "auth_init",
            body: [
                "code_challenge": challenge,
                "code_challenge_method": "S256",
                "state": state,
                "redirect_uri": redirectURI,
                "locale": "zh_CN",
                "login_source": "desktop"
            ]
        )
        guard let authorize = initPayload["authorize_url"] as? String,
              let authorizeURL = URL(string: authorize),
              authorizeURL.scheme == "https",
              authorizeURL.host == platform.host,
              authorizeURL.path == "/dsh/authorize",
              let authorizeID = initPayload["authorize_id"] as? String else {
            throw OAuthError.invalidResponse
        }
        _ = await MainActor.run { NSWorkspace.shared.open(authorizeURL) }

        let callback: String
        do {
            callback = try await Task.detached(priority: .userInitiated) {
                try Self.waitForCallback(fd: listener.fd, expectedState: state)
            }.value
        } catch {
            await cancel(authorizeID: authorizeID, verifier: verifier)
            throw error
        }

        let deviceID: String
        if let stored = UserDefaults.standard.string(forKey: "deepseek.deviceID") {
            deviceID = stored
        } else {
            deviceID = UUID().uuidString.lowercased()
            UserDefaults.standard.set(deviceID, forKey: "deepseek.deviceID")
        }
        let deviceModel = "darwin-\(Self.machineArchitecture())"
        let exchangePayload: [String: Any]
        do {
            exchangePayload = try await post(
                "auth_exchange",
                body: [
                    "code": callback,
                    "code_verifier": verifier,
                    "redirect_uri": redirectURI,
                    "device_id": deviceID,
                    "device_model": deviceModel,
                    "os_version": ProcessInfo.processInfo.operatingSystemVersionString
                ]
            )
        } catch {
            await cancel(authorizeID: authorizeID, verifier: verifier)
            throw error
        }
        guard let token = exchangePayload["token"] as? String, !token.isEmpty,
              let authorized = exchangePayload["authorized_url"] as? String,
              let authorizedURL = URL(string: authorized),
              authorizedURL.scheme == "https",
              authorizedURL.host == platform.host,
              authorizedURL.path == "/dsh/authorized" else {
            throw OAuthError.invalidResponse
        }
        try DeepSeekCredentials.shared.save(token)
        var completed = URLComponents(url: authorizedURL, resolvingAgainstBaseURL: false)!
        var items = completed.queryItems ?? []
        items.removeAll { $0.name == "login_source" }
        items.append(URLQueryItem(name: "login_source", value: "desktop"))
        completed.queryItems = items
        if let url = completed.url {
            _ = await MainActor.run { NSWorkspace.shared.open(url) }
        }
    }

    func signOut() async {
        guard let token = DeepSeekCredentials.shared.read() else { return }
        var request = makeRequest("/auth-api/v0/users/logout", token: token)
        request.httpMethod = "POST"
        _ = try? await session.data(for: request)
        DeepSeekCredentials.shared.delete()
    }

    private func post(_ method: String, body: [String: Any]) async throws -> [String: Any] {
        var request = makeRequest("/auth-api/v0/dsh/\(method)", token: nil)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["code"] as? Int) == 0,
              let outer = json["data"] as? [String: Any],
              (outer["biz_code"] as? Int) == 0,
              let payload = outer["biz_data"] as? [String: Any] else {
            throw OAuthError.platformRejected
        }
        return payload
    }

    private func cancel(authorizeID: String, verifier: String) async {
        var request = makeRequest("/auth-api/v0/dsh/auth_cancel", token: nil)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "authorize_id": authorizeID, "code_verifier": verifier
        ])
        _ = try? await session.data(for: request)
    }

    private func makeRequest(_ path: String, token: String?) -> URLRequest {
        var request = URLRequest(url: platform.appendingPathComponent(String(path.dropFirst())),
                                 timeoutInterval: 25)
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue("", forHTTPHeaderField: "x-client-bundle-id")
        request.setValue("desktop-mac", forHTTPHeaderField: "x-client-platform")
        request.setValue("0.1.0", forHTTPHeaderField: "x-client-version")
        request.setValue("zh_CN", forHTTPHeaderField: "x-client-locale")
        request.setValue("28800", forHTTPHeaderField: "x-client-timezone-offset")
        if let token { request.setValue(token, forHTTPHeaderField: "x-dsh-auth-token") }
        return request
    }

    private func randomURLSafeString(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = bytes.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, byteCount, $0.baseAddress!)
        }
        guard status == errSecSuccess else { throw OAuthError.randomUnavailable }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func makeLoopbackListener() throws -> (fd: Int32, port: UInt16) {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw OAuthError.callbackUnavailable }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindStatus = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindStatus == 0, Darwin.listen(fd, 1) == 0 else {
            Darwin.close(fd)
            throw OAuthError.callbackUnavailable
        }
        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameStatus = withUnsafeMutablePointer(to: &assigned) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fd, $0, &length)
            }
        }
        guard nameStatus == 0 else {
            Darwin.close(fd)
            throw OAuthError.callbackUnavailable
        }
        return (fd, UInt16(bigEndian: assigned.sin_port))
    }

    private static func waitForCallback(fd: Int32, expectedState: String) throws -> String {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = Darwin.poll(&descriptor, 1, 600_000)
        guard ready > 0 else { throw OAuthError.callbackTimedOut }
        let client = Darwin.accept(fd, nil, nil)
        guard client >= 0 else { throw OAuthError.callbackUnavailable }
        defer { Darwin.close(client) }

        var bytes = [UInt8](repeating: 0, count: 16_384)
        let count = Darwin.recv(client, &bytes, bytes.count, 0)
        guard count > 0 else { throw OAuthError.invalidCallback }
        let requestText = String(decoding: bytes.prefix(count), as: UTF8.self)
        guard let firstLine = requestText.components(separatedBy: "\r\n").first else {
            throw OAuthError.invalidCallback
        }
        let fields = firstLine.split(separator: " ")
        guard fields.count >= 2,
              let url = URLComponents(string: "http://localhost\(fields[1])"),
              url.path == "/oauth/callback" else {
            sendCallbackPage(client, success: false)
            throw OAuthError.invalidCallback
        }
        let query = Dictionary(url.queryItems?.map { ($0.name, $0.value ?? "") } ?? [],
                               uniquingKeysWith: { _, last in last })
        guard let code = query["code"], !code.isEmpty,
              let state = query["state"],
              constantTimeEqual(state, expectedState) else {
            sendCallbackPage(client, success: false)
            throw OAuthError.invalidCallback
        }
        sendCallbackPage(client, success: true)
        return code
    }

    private static func sendCallbackPage(_ client: Int32, success: Bool) {
        let text = success
            ? "DeepSeek 登录已完成，可以返回用量监控。"
            : "登录未完成，请返回用量监控后重试。"
        let html = "<!doctype html><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width\"><title>用量监控</title><body style=\"font:16px -apple-system;padding:40px;background:#111;color:#eee\">\(text)</body>"
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
        response.withCString { pointer in _ = Darwin.send(client, pointer, strlen(pointer), 0) }
    }

    private static func constantTimeEqual(_ left: String, _ right: String) -> Bool {
        let a = Array(left.utf8)
        let b = Array(right.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in a.indices { difference |= a[index] ^ b[index] }
        return difference == 0
    }

    private static func machineArchitecture() -> String {
        var system = utsname()
        uname(&system)
        let machine = system.machine
        let machineSize = MemoryLayout.size(ofValue: machine)
        return withUnsafePointer(to: machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: machineSize) {
                String(cString: $0)
            }
        }
    }
}

enum OAuthError: LocalizedError {
    case randomUnavailable, callbackUnavailable, callbackTimedOut, invalidCallback
    case invalidResponse, platformRejected

    var errorDescription: String? {
        switch self {
        case .randomUnavailable: return "无法生成安全登录随机值"
        case .callbackUnavailable: return "无法开启本机浏览器登录回调"
        case .callbackTimedOut: return "登录等待超时，请再试一次"
        case .invalidCallback: return "DeepSeek 登录回调无效"
        case .invalidResponse: return "DeepSeek 返回的数据格式不符合预期"
        case .platformRejected: return "DeepSeek 登录请求未成功，请稍后重试"
        }
    }
}
