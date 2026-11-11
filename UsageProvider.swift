import AppKit
import CryptoKit
import Foundation
import Security

final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum UsagePaths {
    static let platform = URL(string: "https://platform.deepseek.com")!
    static let codexUsage = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    static let keychainService = "studio.aaaaa.usage.deepseek"
}

final class DeepSeekCredentials {
    static let shared = DeepSeekCredentials()
    private let service = UsagePaths.keychainService

    func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "default",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(_ token: String) throws {
        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "default"
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert.merge(attributes) { _, new in new }
            let added = SecItemAdd(insert as CFDictionary, nil)
            guard added == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(added)) }
        } else if status != errSecSuccess {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "default"
        ]
        SecItemDelete(query as CFDictionary)
    }
}

final class UsageProvider {
    private let redirectDelegate = NoRedirectDelegate()
    private lazy var session = URLSession(configuration: .ephemeral, delegate: redirectDelegate, delegateQueue: nil)

    func snapshot() async -> [String: Any] {
        async let codexData = codexSnapshot()
        async let deepSeekData = deepSeekSnapshot()
        return [
            "updatedAt": ISO8601DateFormatter().string(from: Date()),
            "codex": await codexData,
            "deepseek": await deepSeekData
        ]
    }

    private func codexSnapshot() async -> [String: Any] {
        guard let auth = readCodexAuth() else {
            return [
                "available": false, "source": "none",
                "error": "未找到 Codex ChatGPT 登录凭据",
                "primary": NSNull(), "weekly": NSNull()
            ]
        }
        var request = URLRequest(url: UsagePaths.codexUsage, timeoutInterval: 12)
        request.httpMethod = "GET"
        request.setValue("Bearer \(auth.token)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
        request.setValue("AAAAA-Usage-macOS", forHTTPHeaderField: "user-agent")
        if let accountID = auth.accountID {
            request.setValue(accountID, forHTTPHeaderField: "chatgpt-account-id")
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw NSError(domain: "AAAAAUsage.Codex", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "ChatGPT 用量接口暂不可用"])
            }
            let limits = payload["rate_limit"] as? [String: Any] ?? [:]
            return [
                "available": true, "source": "live",
                "email": payload["email"] as? String ?? "",
                "planType": payload["plan_type"] as? String ?? "",
                "primary": liveWindow(limits["primary_window"], fallbackSeconds: 18_000),
                "weekly": liveWindow(limits["secondary_window"], fallbackSeconds: 604_800),
                "rateLimitReached": limits["limit_reached"] as? Bool ?? false,
                "error": ""
            ]
        } catch {
            if let cached = readCodexSessionUsage() {
                return [
                    "available": true, "source": "session",
                    "email": "", "planType": "",
                    "primary": cached.primary, "weekly": cached.weekly,
                    "rateLimitReached": false,
                    "updatedAt": cached.updatedAt,
                    "error": "实时接口不可用，显示最近的本地会话快照"
                ]
            }
            return [
                "available": false, "source": "none",
                "email": "", "planType": "",
                "primary": NSNull(), "weekly": NSNull(),
                "error": error.localizedDescription
            ]
        }
    }

    private func liveWindow(_ value: Any?, fallbackSeconds: Double) -> [String: Any] {
        guard let window = value as? [String: Any] else {
            return ["usedPercent": 0, "windowSeconds": fallbackSeconds, "resetAt": NSNull()]
        }
        let resetAt = number(window["reset_at"])
        let resetAfter = number(window["reset_after_seconds"])
        let reset: Any = resetAt > 0 ? resetAt * 1000
            : (resetAfter > 0 ? Date().timeIntervalSince1970 * 1000 + resetAfter * 1000 : NSNull())
        return [
            "usedPercent": number(window["used_percent"]),
            "windowSeconds": max(1, number(window["limit_window_seconds"], fallback: fallbackSeconds)),
            "resetAt": reset
        ]
    }

    private func readCodexAuth() -> (token: String, accountID: String?)? {
        let home = ProcessInfo.processInfo.environment["DSH_CODEX_USAGE_HOME"]
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex").path
        let file = URL(fileURLWithPath: home).appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = object["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String, !token.isEmpty else { return nil }
        return (token, tokens["account_id"] as? String)
    }

    private func readCodexSessionUsage() -> (primary: [String: Any], weekly: [String: Any], updatedAt: String)? {
        let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/sessions")
        let calendar = Calendar.current
        for offset in 0..<14 {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: Date()) else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            guard let year = parts.year, let month = parts.month, let date = parts.day else { continue }
            let folder = root
                .appendingPathComponent(String(format: "%04d", year))
                .appendingPathComponent(String(format: "%02d", month))
                .appendingPathComponent(String(format: "%02d", date))
            guard let files = try? FileManager.default.contentsOfDirectory(at: folder,
                    includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            let recent = files.filter { $0.pathExtension == "jsonl" }
                .sorted {
                    let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return a > b
                }
            for file in recent.prefix(3) {
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
                      let size = attrs[.size] as? NSNumber,
                      let handle = try? FileHandle(forReadingFrom: file) else { continue }
                defer { try? handle.close() }
                let count = min(Int(size.intValue), 384 * 1024)
                guard count > 0 else { continue }
                try? handle.seek(toOffset: UInt64(max(0, size.intValue - count)))
                let tail = (try? handle.readToEnd()) ?? Data()
                for line in tail.split(separator: 0x0A).reversed() {
                    guard let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                          let payload = entry["payload"] as? [String: Any],
                          let limits = payload["rate_limits"] as? [String: Any] else { continue }
                    let time = entry["timestamp"] as? String ?? ""
                    return (
                        sessionWindow(limits["primary"], fallbackSeconds: 18_000),
                        sessionWindow(limits["secondary"], fallbackSeconds: 604_800),
                        time
                    )
                }
            }
        }
        return nil
    }

    private func sessionWindow(_ value: Any?, fallbackSeconds: Double) -> [String: Any] {
        guard let window = value as? [String: Any] else {
            return ["usedPercent": 0, "windowSeconds": fallbackSeconds, "resetAt": NSNull()]
        }
        let minutes = number(window["window_minutes"])
        let reset = number(window["resets_at"])
        return [
            "usedPercent": number(window["used_percent"]),
            "windowSeconds": minutes > 0 ? minutes * 60 : fallbackSeconds,
            "resetAt": reset > 0 ? reset * 1000 : NSNull()
        ]
    }

    private func deepSeekSnapshot() async -> [String: Any] {
        let localTokens = readDeepSeekTokenCache()
        guard let token = DeepSeekCredentials.shared.read() else {
            return [
                "signedIn": false, "profile": NSNull(),
                "balanceAvailable": false, "balances": [],
                "officialSpendAvailable": false, "officialSpend": [],
                "tokens": localTokens, "error": ""
            ]
        }

        async let summaryResult = platformGET("/api/v0/users/get_user_summary", token: token)
        async let profileResult = platformGET("/auth-api/v0/users/current", token: token)
        let summary = await summaryResult
        let user = await profileResult

        var balances: [[String: Any]] = []
        var officialCosts: [[String: Any]] = []
        var balanceAvailable = false
        var officialAvailable = false
        if let summary,
           let normal = summary["normal_wallets"] as? [[String: Any]] {
            balances = normal.compactMap { wallet in
                guard let currency = wallet["currency"] as? String,
                      let amount = decimalString(wallet["balance"]) else { return nil }
                return ["currency": currency, "amount": amount]
            }
            balanceAvailable = !balances.isEmpty
            if let costs = summary["total_costs"] as? [[String: Any]] {
                officialCosts = costs.compactMap { item in
                    guard let currency = item["currency"] as? String,
                          currency == "CNY" || currency == "USD",
                          let amount = decimalString(item["amount"]) else { return nil }
                    return ["currency": currency, "amount": amount]
                }
                officialAvailable = officialCosts.count == costs.count
            }
        }

        var profile: [String: Any] = [:]
        if let user {
            profile["name"] = (user["id_profile"] as? [String: Any])?["name"] as? String ?? ""
            profile["contact"] = user["mobile"] as? String
                ?? user["mobile_number"] as? String
                ?? user["email"] as? String ?? ""
        }
        return [
            "signedIn": true,
            "profile": profile.isEmpty ? NSNull() : profile,
            "balanceAvailable": balanceAvailable,
            "balances": balances,
            "officialSpendAvailable": officialAvailable,
            "officialSpend": officialCosts,
            "tokens": localTokens,
            "error": balanceAvailable ? "" : "账户摘要暂时不可用"
        ]
    }

    private func platformGET(_ path: String, token: String) async -> [String: Any]? {
        var request = URLRequest(url: UsagePaths.platform.appendingPathComponent(String(path.dropFirst())),
                                 timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue(token, forHTTPHeaderField: "x-dsh-auth-token")
        request.setValue("", forHTTPHeaderField: "x-client-bundle-id")
        request.setValue("desktop-mac", forHTTPHeaderField: "x-client-platform")
        request.setValue("0.1.0", forHTTPHeaderField: "x-client-version")
        request.setValue("zh_CN", forHTTPHeaderField: "x-client-locale")
        request.setValue("28800", forHTTPHeaderField: "x-client-timezone-offset")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let envelope = payload["data"] as? [String: Any],
                  (payload["code"] as? Int) == 0, (envelope["biz_code"] as? Int) == 0 else { return nil }
            return envelope["biz_data"] as? [String: Any]
        } catch {
            return nil
        }
    }

    private func readDeepSeekTokenCache() -> [String: Any] {
        let root = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".dsh/storages/session_projcache/sessions")
        guard let files = try? FileManager.default.contentsOfDirectory(at: root,
                includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return zeroTokens(available: false, sessions: 0)
        }
        var totals = ["inputTokens": 0.0, "cacheReadTokens": 0.0, "outputTokens": 0.0,
                      "cacheWriteTokens": 0.0]
        var scanned = 0
        let ordered = files.filter { $0.pathExtension == "json" }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
        for file in ordered.prefix(200) {
            guard let data = try? Data(contentsOf: file),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let record = root["record"] as? [String: Any],
                  let rows = record["rows"] as? [String: Any],
                  let tokenUsage = rows["tokenUsage"] as? [String: Any],
                  let value = tokenUsage["val"] as? [String: Any],
                  let usage = value["totals"] as? [String: Any] else { continue }
            scanned += 1
            totals["inputTokens", default: 0] += number(usage["uncachedInputTokens"] ?? usage["inputTokens"])
            totals["cacheReadTokens", default: 0] += number(usage["cacheReadTokens"])
            totals["outputTokens", default: 0] += number(usage["outputTokens"])
            totals["cacheWriteTokens", default: 0] += number(usage["cacheWriteTokens"])
        }
        let input = totals["inputTokens", default: 0]
        let cached = totals["cacheReadTokens", default: 0]
        let output = totals["outputTokens", default: 0]
        let write = totals["cacheWriteTokens", default: 0]
        return [
            "available": scanned > 0, "sessions": scanned,
            "inputTokens": input, "cacheReadTokens": cached,
            "cacheWriteTokens": write, "outputTokens": output,
            "totalTokens": input + cached + output,
            "source": "本机 DeepSeek Harness 会话投影"
        ]
    }

    private func zeroTokens(available: Bool, sessions: Int) -> [String: Any] {
        [
            "available": available, "sessions": sessions, "inputTokens": 0,
            "cacheReadTokens": 0, "cacheWriteTokens": 0, "outputTokens": 0,
            "totalTokens": 0, "source": "本机 DeepSeek Harness 会话投影"
        ]
    }

    private func decimalString(_ value: Any?) -> String? {
        if let string = value as? String,
           Decimal(string: string, locale: Locale(identifier: "en_US_POSIX")) != nil { return string }
        if let number = value as? NSNumber, number.doubleValue.isFinite { return number.stringValue }
        return nil
    }

    private func number(_ value: Any?, fallback: Double = 0) -> Double {
        if let number = value as? NSNumber, number.doubleValue.isFinite { return number.doubleValue }
        if let string = value as? String, let parsed = Double(string), parsed.isFinite { return parsed }
        return fallback
    }
}
