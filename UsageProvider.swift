import CryptoKit
import Foundation

private func forEachZstdRecordLine(at url: URL, maximumRecordSize: Int,
                                   processRecord: (Data) -> Void) -> Bool {
    let candidates = ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/usr/bin/zstd"]
    guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
        return false
    }

    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = ["-dc", url.path]
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        return false
    }
    try? output.fileHandleForWriting.close()

    let reader = output.fileHandleForReading
    let chunkSize = 256 * 1024
    var pending = Data()
    var skippingOversizedRecord = false
    while true {
        let chunk: Data
        do {
            guard let next = try reader.read(upToCount: chunkSize), !next.isEmpty else { break }
            chunk = next
        } catch {
            break
        }

        if skippingOversizedRecord {
            guard let newline = chunk.firstIndex(of: 0x0A) else { continue }
            skippingOversizedRecord = false
            let remainderStart = chunk.index(after: newline)
            if remainderStart < chunk.endIndex { pending.append(contentsOf: chunk[remainderStart...]) }
        } else {
            pending.append(chunk)
        }

        var searchStart = pending.startIndex
        var consumedThrough = pending.startIndex
        while searchStart < pending.endIndex,
              let newline = pending[searchStart..<pending.endIndex].firstIndex(of: 0x0A) {
            if consumedThrough < newline {
                let line = Data(pending[consumedThrough..<newline])
                autoreleasepool { processRecord(line) }
            }
            consumedThrough = pending.index(after: newline)
            searchStart = consumedThrough
        }
        if consumedThrough > pending.startIndex {
            pending.removeSubrange(pending.startIndex..<consumedThrough)
        }
        if pending.count > maximumRecordSize {
            pending.removeAll(keepingCapacity: true)
            skippingOversizedRecord = true
        }
    }
    if !skippingOversizedRecord, !pending.isEmpty {
        autoreleasepool { processRecord(pending) }
    }
    try? reader.close()
    process.waitUntilExit()
    return process.terminationStatus == 0
}

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
}

struct ToolAvailability {
    let codex: Bool
    let deepSeek: Bool
    let kimi: Bool

    var hasAny: Bool { codex || deepSeek || kimi }

    var dictionary: [String: Bool] {
        ["codex": codex, "deepseek": deepSeek, "kimi": kimi]
    }

    static func detect() -> ToolAvailability {
        let fileManager = FileManager.default
        let environment = ProcessInfo.processInfo.environment
        let codexHome = environment["DSH_CODEX_USAGE_HOME"]
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex").path
        let codexRoot = URL(fileURLWithPath: codexHome)
        let codexConfigExists = fileManager.fileExists(
            atPath: codexRoot.appendingPathComponent("auth.json").path
        ) || fileManager.fileExists(
            atPath: codexRoot.appendingPathComponent("sessions").path
        )
        let codexAppExists = applicationExists(named: "ChatGPT.app", fileManager: fileManager)
            || applicationExists(named: "Codex.app", fileManager: fileManager)

        let deepSeekHome = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".dsh")
        let deepSeekFilesExist = fileManager.fileExists(atPath: deepSeekHome.path)
        let deepSeekAppExists = applicationExists(
            named: "DeepSeek Harness.app", fileManager: fileManager
        )
        return ToolAvailability(
            codex: codexConfigExists || codexAppExists || executableExists(
                named: "codex", environment: environment, fileManager: fileManager
            ),
            deepSeek: deepSeekFilesExist || deepSeekAppExists || executableExists(
                named: "dsh", environment: environment, fileManager: fileManager
            ),
            // Keep the Kimi card visible; live usage reuses the desktop app's local session.
            kimi: true
        )
    }

    private static func applicationExists(named name: String, fileManager: FileManager) -> Bool {
        let roots = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications")
        ]
        return roots.contains { fileManager.fileExists(atPath: $0.appendingPathComponent(name).path) }
    }

    private static func executableExists(
        named name: String,
        environment: [String: String],
        fileManager: FileManager
    ) -> Bool {
        let pathDirectories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let candidates = pathDirectories + [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/bin").path
        ]
        let uniqueDirectories = Set(candidates)
        return uniqueDirectories.contains {
            fileManager.isExecutableFile(atPath: URL(fileURLWithPath: $0)
                .appendingPathComponent(name).path)
        }
    }
}

private enum KimiDesktopSessionStore {
    struct Credentials {
        let origin: String
        let accessToken: String
    }

    private struct Entry {
        let sequence: UInt64
        let deleted: Bool
        let value: [UInt8]
    }

    static func credentials() -> [Credentials] {
        let directory = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/kimi-desktop/Local Storage/leveldb")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return [] }

        var latest: [Data: Entry] = [:]
        for file in files where file.pathExtension == "ldb" {
            guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= 64 * 1024 * 1024,
                  let data = try? Data(contentsOf: file) else { continue }
            readTable(Array(data), into: &latest)
        }
        for file in files where file.pathExtension == "log" {
            guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= 64 * 1024 * 1024,
                  let data = try? Data(contentsOf: file) else { continue }
            readLog(Array(data), into: &latest)
        }

        var stored: [String: (UInt64, String)] = [:]
        for (key, entry) in latest where !entry.deleted {
            let keyText = String(decoding: key, as: UTF8.self)
            guard let origin = ["https://www.kimi.com", "https://www.kimi.ai"]
                .first(where: { keyText.contains($0) }),
                  keyText.contains("access_token"),
                  !keyText.contains("anonymous_access_token") else { continue }
            guard let token = tokenString(entry.value) else { continue }
            if let previous = stored[origin], previous.0 >= entry.sequence { continue }
            stored[origin] = (entry.sequence, token)
        }

        return stored.map { origin, storedToken in
            let accessToken = storedToken.1
            return Credentials(
                origin: origin,
                accessToken: accessToken
            )
        }.sorted {
            let firstExpiry = jwtClaims($0.accessToken)?["exp"] as? TimeInterval ?? 0
            let secondExpiry = jwtClaims($1.accessToken)?["exp"] as? TimeInterval ?? 0
            return firstExpiry > secondExpiry
        }
    }

    private static func tokenString(_ bytes: [UInt8]) -> String? {
        var valueBytes = bytes
        if valueBytes.first == 1 { valueBytes.removeFirst() }
        guard var value = String(bytes: valueBytes, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              value.count >= 100,
              !value.contains(where: { $0.isWhitespace }) else { return nil }
        if value.first == "\"", value.last == "\"" {
            value.removeFirst()
            value.removeLast()
        }
        return value.isEmpty ? nil : value
    }

    static func jwtClaims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count > 1 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload.append("=") }
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return claims
    }

}

extension KimiDesktopSessionStore {
    private static func readTable(_ bytes: [UInt8], into latest: inout [Data: Entry]) {
        guard bytes.count >= 48 else { return }
        var footerOffset = bytes.count - 48
        guard readBlockHandle(bytes, offset: &footerOffset) != nil,
              let indexHandle = readBlockHandle(bytes, offset: &footerOffset),
              let index = readBlock(bytes, handle: indexHandle),
              let indexEntries = blockEntries(index) else { return }
        for (_, handleBytes) in indexEntries {
            var offset = 0
            guard let handle = readBlockHandle(handleBytes, offset: &offset),
                  let dataBlock = readBlock(bytes, handle: handle),
                  let records = blockEntries(dataBlock) else { continue }
            for (internalKey, value) in records {
                guard internalKey.count >= 8 else { continue }
                let trailerStart = internalKey.count - 8
                var trailer: UInt64 = 0
                for index in 0..<8 {
                    trailer |= UInt64(internalKey[trailerStart + index]) << (index * 8)
                }
                let key = Data(internalKey[..<trailerStart])
                let entry = Entry(
                    sequence: trailer >> 8,
                    deleted: trailer & 0xff == 0,
                    value: value
                )
                if latest[key].map({ $0.sequence < entry.sequence }) ?? true {
                    latest[key] = entry
                }
            }
        }
    }

    private static func readLog(_ bytes: [UInt8], into latest: inout [Data: Entry]) {
        let blockSize = 32 * 1024
        var position = 0
        var fragment: [UInt8] = []
        var hasFragment = false
        while position + 7 <= bytes.count {
            let blockOffset = position % blockSize
            if blockOffset + 7 > blockSize {
                position += blockSize - blockOffset
                continue
            }
            let length = Int(bytes[position + 4]) | (Int(bytes[position + 5]) << 8)
            let type = bytes[position + 6]
            let recordStart = position + 7
            let blockEnd = min(bytes.count, position - blockOffset + blockSize)
            guard recordStart + length <= blockEnd else { break }
            position = recordStart + length
            if type == 0 {
                fragment.removeAll(keepingCapacity: true)
                hasFragment = false
                continue
            }
            let chunk = Array(bytes[recordStart..<(recordStart + length)])
            switch type {
            case 1:
                readBatch(chunk, into: &latest)
                fragment.removeAll(keepingCapacity: true)
                hasFragment = false
            case 2:
                fragment = chunk
                hasFragment = true
            case 3 where hasFragment:
                fragment.append(contentsOf: chunk)
            case 4 where hasFragment:
                fragment.append(contentsOf: chunk)
                readBatch(fragment, into: &latest)
                fragment.removeAll(keepingCapacity: true)
                hasFragment = false
            default:
                fragment.removeAll(keepingCapacity: true)
                hasFragment = false
            }
        }
    }

    private static func readBatch(_ bytes: [UInt8], into latest: inout [Data: Entry]) {
        guard bytes.count >= 12 else { return }
        var sequence: UInt64 = 0
        for index in 0..<8 { sequence |= UInt64(bytes[index]) << (index * 8) }
        let count = Int(bytes[8]) | (Int(bytes[9]) << 8)
            | (Int(bytes[10]) << 16) | (Int(bytes[11]) << 24)
        guard count <= 100_000 else { return }
        var position = 12
        for index in 0..<count {
            guard position < bytes.count else { return }
            let type = bytes[position]
            position += 1
            guard let keyLength = readVarint(bytes, offset: &position),
                  keyLength <= UInt64(bytes.count - position) else { return }
            let key = Data(bytes[position..<(position + Int(keyLength))])
            position += Int(keyLength)
            var value: [UInt8] = []
            if type == 1 {
                guard let valueLength = readVarint(bytes, offset: &position),
                      valueLength <= UInt64(bytes.count - position) else { return }
                value = Array(bytes[position..<(position + Int(valueLength))])
                position += Int(valueLength)
            } else if type != 0 {
                return
            }
            let entry = Entry(sequence: sequence + UInt64(index), deleted: type == 0, value: value)
            if latest[key].map({ $0.sequence < entry.sequence }) ?? true {
                latest[key] = entry
            }
        }
    }

    private static func readBlockHandle(
        _ bytes: [UInt8], offset: inout Int
    ) -> (offset: Int, size: Int)? {
        guard let blockOffset = readVarint(bytes, offset: &offset),
              let blockSize = readVarint(bytes, offset: &offset),
              blockOffset <= UInt64(Int.max), blockSize <= UInt64(Int.max) else { return nil }
        return (Int(blockOffset), Int(blockSize))
    }

    private static func readBlock(
        _ file: [UInt8], handle: (offset: Int, size: Int)
    ) -> [UInt8]? {
        guard handle.offset >= 0, handle.size >= 0,
              handle.offset + handle.size < file.count else { return nil }
        let bytes = Array(file[handle.offset..<(handle.offset + handle.size)])
        switch file[handle.offset + handle.size] {
        case 0: return bytes
        case 1: return decodeSnappy(bytes)
        default: return nil
        }
    }

    private static func blockEntries(_ bytes: [UInt8]) -> [([UInt8], [UInt8])]? {
        guard bytes.count >= 4 else { return nil }
        let restartCount = Int(bytes[bytes.count - 4]) | (Int(bytes[bytes.count - 3]) << 8)
            | (Int(bytes[bytes.count - 2]) << 16) | (Int(bytes[bytes.count - 1]) << 24)
        guard restartCount > 0, restartCount <= (bytes.count - 4) / 4 else { return nil }
        let contentEnd = bytes.count - 4 - restartCount * 4
        var position = 0
        var previous: [UInt8] = []
        var output: [([UInt8], [UInt8])] = []
        while position < contentEnd {
            guard let shared = readVarint(bytes, offset: &position),
                  let unshared = readVarint(bytes, offset: &position),
                  let valueLength = readVarint(bytes, offset: &position),
                  shared <= UInt64(previous.count),
                  unshared <= UInt64(contentEnd - position),
                  valueLength <= UInt64(contentEnd - position - Int(unshared)) else { return nil }
            var key = Array(previous.prefix(Int(shared)))
            key.append(contentsOf: bytes[position..<(position + Int(unshared))])
            position += Int(unshared)
            let value = Array(bytes[position..<(position + Int(valueLength))])
            position += Int(valueLength)
            output.append((key, value))
            previous = key
        }
        return output
    }

    private static func decodeSnappy(_ bytes: [UInt8]) -> [UInt8]? {
        var position = 0
        guard let expectedLength = readVarint(bytes, offset: &position),
              expectedLength <= 64 * 1024 * 1024 else { return nil }
        var output: [UInt8] = []
        output.reserveCapacity(Int(expectedLength))
        while position < bytes.count, output.count < Int(expectedLength) {
            let tag = bytes[position]
            position += 1
            switch tag & 0x03 {
            case 0:
                var length = Int(tag >> 2)
                if length < 60 {
                    length += 1
                } else {
                    let extraBytes = length - 59
                    guard extraBytes <= 4, position + extraBytes <= bytes.count else { return nil }
                    length = 0
                    for index in 0..<extraBytes {
                        length |= Int(bytes[position + index]) << (index * 8)
                    }
                    position += extraBytes
                    length += 1
                }
                guard position + length <= bytes.count else { return nil }
                output.append(contentsOf: bytes[position..<(position + length)])
                position += length
            case 1, 2, 3:
                let kind = tag & 0x03
                let length = kind == 1 ? 4 + Int((tag >> 2) & 0x07) : 1 + Int(tag >> 2)
                let distance: Int
                if kind == 1 {
                    guard position < bytes.count else { return nil }
                    distance = (Int(tag & 0xe0) << 3) | Int(bytes[position])
                    position += 1
                } else {
                    let count = kind == 2 ? 2 : 4
                    guard position + count <= bytes.count else { return nil }
                    distance = bytes[position..<(position + count)].enumerated().reduce(0) {
                        $0 | (Int($1.element) << ($1.offset * 8))
                    }
                    position += count
                }
                guard distance > 0, distance <= output.count else { return nil }
                for _ in 0..<length { output.append(output[output.count - distance]) }
            default:
                return nil
            }
        }
        return output.count == Int(expectedLength) ? output : nil
    }

    private static func readVarint(_ bytes: [UInt8], offset: inout Int) -> UInt64? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while offset < bytes.count, shift < 64 {
            let byte = bytes[offset]
            offset += 1
            value |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
        return nil
    }
}

private enum KimiAccountError: LocalizedError, Equatable {
    case noDesktopSession
    case usageUnavailable(String?)
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .noDesktopSession:
            return "未检测到可用的 Kimi 桌面端会话，暂时无法读取账户额度。"
        case .usageUnavailable(let detail):
            return detail ?? "检测到 Kimi 桌面端会话，但暂时无法读取额度。"
        case .httpStatus(let status):
            return "HTTP \(status)"
        }
    }
}

final class KimiAccountClient {
    private let membershipStatsPath =
        "/apiv2/kimi.gateway.membership.v2.MembershipService/GetSubscriptionStats"
    private let codingUsageURL = URL(string: "https://api.kimi.com/coding/v1/usages")!
    private let session = URLSession(
        configuration: .ephemeral,
        delegate: NoRedirectDelegate(),
        delegateQueue: nil
    )
    func fetchUsage() async -> [String: Any] {
        let credentials = KimiDesktopSessionStore.credentials()
        guard !credentials.isEmpty else {
            return usageUnavailable(
                sessionDetected: false,
                message: KimiAccountError.noDesktopSession.localizedDescription
            )
        }

        var membershipFailures: [String] = []
        var codingFailures: [String] = []
        for credential in credentials.prefix(4) {
            do {
                return try await fetchMembershipStats(
                    accessToken: credential.accessToken,
                    origin: credential.origin
                )
            } catch {
                membershipFailures.append(failureDescription(error))
            }
        }
        for credential in credentials.prefix(4) {
            do {
                var usage = try await fetchCodingUsage(accessToken: credential.accessToken)
                usage["membershipUnavailable"] = membershipFailures.first ?? "额度不可用"
                return usage
            } catch {
                codingFailures.append(failureDescription(error))
            }
        }
        let membershipDetail = membershipFailures.first ?? "额度不可用"
        let codingDetail = codingFailures.first ?? "用量不可用"
        let membershipUnauthorized = membershipFailures.contains {
            $0.contains("HTTP 401") || $0.contains("HTTP 403")
        }
        let nextStep = membershipUnauthorized
            ? "Kimi 本机会话已过期；请在 Kimi 桌面端切到 Chat 页面等待其自动续期，本应用会重新读取会话，不会另存凭据。"
            : "请检查 Kimi 桌面端账号状态和网络后重试。"
        let detail = "会员接口：" + membershipDetail
            + "；Kimi Code 接口：" + codingDetail
            + "。" + nextStep
        return usageUnavailable(
            sessionDetected: true,
            message: KimiAccountError.usageUnavailable(detail).localizedDescription
        )
    }

    private func fetchMembershipStats(accessToken: String, origin: String) async throws -> [String: Any] {
        guard ["https://www.kimi.com", "https://www.kimi.ai"].contains(origin),
              let url = URL(string: origin + membershipStatsPath) else {
            throw KimiAccountError.usageUnavailable("Kimi 桌面会话站点不受支持")
        }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.httpBody = Data("{}".utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw KimiAccountError.usageUnavailable("没有收到 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw KimiAccountError.httpStatus(http.statusCode)
        }
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw KimiAccountError.usageUnavailable("会员接口返回了无法解析的数据")
        }
        let responseData = payload["data"] as? [String: Any] ?? payload
        let stats = responseData["data"] as? [String: Any] ?? responseData
        let monthly = quotaWindow(
            stats["subscriptionBalance"] as? [String: Any]
                ?? stats["subscription_balance"] as? [String: Any],
            ratioKeys: ["amountUsedRatio", "amount_used_ratio", "usedRatio", "used_ratio"],
            resetKeys: ["expireTime", "expire_time", "resetTime", "reset_time"]
        )
        let codeFiveHour = quotaWindow(
            stats["ratelimitCode5h"] as? [String: Any]
                ?? stats["ratelimit_code_5h"] as? [String: Any],
            ratioKeys: ["ratio", "usedRatio", "used_ratio"],
            resetKeys: ["resetTime", "reset_time", "expireTime", "expire_time"]
        )
        let codeWeekly = quotaWindow(
            stats["ratelimitCode7d"] as? [String: Any]
                ?? stats["ratelimit_code_7d"] as? [String: Any],
            ratioKeys: ["ratio", "usedRatio", "used_ratio"],
            resetKeys: ["resetTime", "reset_time", "expireTime", "expire_time"]
        )
        guard monthly != nil || codeFiveHour != nil || codeWeekly != nil else {
            throw KimiAccountError.usageUnavailable("会员接口返回中没有识别到额度字段")
        }
        return [
            "available": true,
            "sessionDetected": true,
            "source": "kimiDesktop",
            "monthly": monthly.map { $0 as Any } ?? NSNull(),
            "fiveHour": NSNull(),
            "codeFiveHour": codeFiveHour.map { $0 as Any } ?? NSNull(),
            "codeWeekly": codeWeekly.map { $0 as Any } ?? NSNull(),
            "tokens": unavailableTokenUsage(),
            "error": ""
        ]
    }

    private func fetchCodingUsage(accessToken: String) async throws -> [String: Any] {
        var request = URLRequest(url: codingUsageURL, timeoutInterval: 12)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw KimiAccountError.usageUnavailable("没有收到 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw KimiAccountError.httpStatus(http.statusCode)
        }
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw KimiAccountError.usageUnavailable("Kimi Code 接口返回了无法解析的数据")
        }
        let envelope = payload["data"] as? [String: Any] ?? payload
        if envelope["kind"] as? String == "error" {
            let status = (envelope["status"] as? NSNumber)?.intValue
            throw KimiAccountError.usageUnavailable(
                status.map { "Kimi Code 接口状态 \($0)" } ?? "Kimi Code 接口报告读取失败"
            )
        }
        let quota = envelope["quota"] as? [String: Any] ?? envelope
        let usages = quota["usages"] as? [String: Any] ?? envelope["usages"] as? [String: Any] ?? [:]
        let fiveHour = quotaWindow(
            firstDictionary(in: usages, keys: ["limit5h", "limit_5h"]),
            ratioKeys: ["usedRatio", "used_ratio", "ratio"],
            resetKeys: ["resetAt", "reset_at", "resetTime", "reset_time"],
            usedKeys: ["used"], limitKeys: ["limit"], remainingKeys: ["remaining"]
        ) ?? parseLegacyFiveHourLimit(quota) ?? parseLegacyFiveHourLimit(envelope)
        let weekly = quotaWindow(
            firstDictionary(in: usages, keys: ["limit7d", "limit_7d"]),
            ratioKeys: ["usedRatio", "used_ratio", "ratio"],
            resetKeys: ["resetAt", "reset_at", "resetTime", "reset_time"],
            usedKeys: ["used"], limitKeys: ["limit"], remainingKeys: ["remaining"]
        ) ?? quotaWindow(
            (quota["usage"] as? [String: Any]) ?? (envelope["usage"] as? [String: Any]),
            ratioKeys: ["usedRatio", "used_ratio", "ratio"],
            resetKeys: ["resetAt", "reset_at", "resetTime", "reset_time"],
            usedKeys: ["used"], limitKeys: ["limit"], remainingKeys: ["remaining"]
        )
        let monthly = quotaWindow(
            firstDictionary(in: usages, keys: ["monthTotal", "month_total", "limitMonthTotal", "limit_month_total"]),
            ratioKeys: ["usedRatio", "used_ratio", "ratio"],
            resetKeys: ["resetAt", "reset_at", "resetTime", "reset_time"],
            usedKeys: ["used"], limitKeys: ["limit"], remainingKeys: ["remaining"]
        )
        guard fiveHour != nil || weekly != nil || monthly != nil else {
            throw KimiAccountError.usageUnavailable("Kimi Code 接口返回中没有识别到额度字段")
        }
        return [
            "available": true,
            "sessionDetected": true,
            "source": "kimiCode",
            "monthly": monthly.map { $0 as Any } ?? NSNull(),
            "fiveHour": fiveHour.map { $0 as Any } ?? NSNull(),
            "codeFiveHour": NSNull(),
            "codeWeekly": weekly.map { $0 as Any } ?? NSNull(),
            "tokens": unavailableTokenUsage(),
            "error": ""
        ]
    }

    private func quotaWindow(_ source: [String: Any]?, ratioKeys: [String],
                             resetKeys: [String], usedKeys: [String] = [],
                             limitKeys: [String] = [], remainingKeys: [String] = []) -> [String: Any]? {
        guard let source else { return nil }
        var ratio = ratioKeys.compactMap { source[$0] }.first.map(numericValue) ?? .nan
        if !ratio.isFinite,
           let used = usedKeys.compactMap({ source[$0] }).first.map(numericValue),
           let limit = limitKeys.compactMap({ source[$0] }).first.map(numericValue), limit > 0 {
            ratio = used / limit
        }
        if !ratio.isFinite,
           let remaining = remainingKeys.compactMap({ source[$0] }).first.map(numericValue),
           let limit = limitKeys.compactMap({ source[$0] }).first.map(numericValue), limit > 0 {
            ratio = 1 - (remaining / limit)
        }
        if ratio > 1 && ratio <= 100 { ratio /= 100 }
        guard ratio.isFinite, (0...1).contains(ratio) else { return nil }
        let resetAt = resetTimestamp(resetKeys.compactMap { source[$0] }.first)
        return ["usedPercent": ratio * 100, "resetAt": resetAt.map { $0 as Any } ?? NSNull()]
    }

    private func firstDictionary(in source: [String: Any], keys: [String]) -> [String: Any]? {
        keys.compactMap { source[$0] as? [String: Any] }.first
    }

    private func parseLegacyFiveHourLimit(_ envelope: [String: Any]) -> [String: Any]? {
        guard let limits = envelope["limits"] as? [[String: Any]] else { return nil }
        for entry in limits {
            let window = entry["window"] as? [String: Any] ?? [:]
            let duration = numericValue(window["duration"] ?? NSNull())
            let unit = window["timeUnit"] as? String ?? ""
            guard duration == 300 && unit == "TIME_UNIT_MINUTE",
                  let detail = entry["detail"] as? [String: Any] else { continue }
            if let parsed = quotaWindow(
                detail,
                ratioKeys: ["usedRatio", "used_ratio", "ratio"],
                resetKeys: ["resetAt", "reset_at", "resetTime", "reset_time"],
                usedKeys: ["used"], limitKeys: ["limit"], remainingKeys: ["remaining"]
            ) {
                return parsed
            }
        }
        return nil
    }

    private func failureDescription(_ error: Error) -> String {
        if let kimiError = error as? KimiAccountError,
           let detail = kimiError.errorDescription {
            return detail
        }
        if let urlError = error as? URLError {
            return "网络错误（\(urlError.code.rawValue)）"
        }
        return "请求或数据解析失败"
    }

    private func numericValue(_ value: Any) -> Double {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) ?? .nan }
        return .nan
    }

    private func resetTimestamp(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            let raw = number.doubleValue
            return raw > 100_000_000_000 ? raw : raw * 1000
        }
        guard let string = value as? String else { return nil }
        if let number = Double(string) {
            return number > 100_000_000_000 ? number : number * 1000
        }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: string) { return date.timeIntervalSince1970 * 1000 }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string).map { $0.timeIntervalSince1970 * 1000 }
    }

    private func usageUnavailable(sessionDetected: Bool, message: String) -> [String: Any] {
        [
            "available": false,
            "sessionDetected": sessionDetected,
            "source": "none",
            "monthly": NSNull(),
            "fiveHour": NSNull(),
            "codeFiveHour": NSNull(),
            "codeWeekly": NSNull(),
            "tokens": unavailableTokenUsage(),
            "error": message
        ]
    }

    private func unavailableTokenUsage() -> [String: Any] {
        [
            "available": false, "sessions": 0,
            "inputTokens": 0, "cacheReadTokens": 0,
            "cacheWriteTokens": 0, "outputTokens": 0, "totalTokens": 0,
            "source": "none",
            "reason": "Kimi 会员额度接口不提供 Token 分项统计"
        ]
    }
}

private struct CodexSessionTokenSnapshot: Sendable {
    let available: Bool
    let sessions: Int
    let inputTokens: Double
    let cacheReadTokens: Double
    let outputTokens: Double
    let totalTokens: Double
    let todayAvailable: Bool
    let todayTokens: Double
    let sessionSummaries: [CodexSessionSummary]

    var dictionary: [String: Any] {
        [
            "available": available,
            "sessions": sessions,
            "inputTokens": inputTokens,
            "cacheReadTokens": cacheReadTokens,
            "cacheWriteTokens": 0,
            "outputTokens": outputTokens,
            "totalTokens": totalTokens,
            "todayAvailable": todayAvailable,
            "todayTokens": todayTokens,
            "source": "本机 ChatGPT 会话记录",
            "reason": available ? "" : "未检测到本机 ChatGPT Token 会话记录"
        ]
    }
}

private struct TodayTokenUsage: Sendable {
    let available: Bool
    let totalTokens: Double
}

private struct CodexSessionSummary: Sendable {
    let id: String
    let title: String
    let project: String
    let updatedAt: Double
    let tokens: LocalSessionTokenUsage?

    var dictionary: [String: Any] {
        [
            "id": id, "title": title, "project": project, "updatedAt": updatedAt,
            "tokensAvailable": tokens != nil,
            "tokens": tokens?.dictionary ?? [:]
        ]
    }
}

private struct LocalSessionTokenUsage: Sendable {
    let inputTokens: Double
    let cacheReadTokens: Double
    let outputTokens: Double
    let totalTokens: Double

    var dictionary: [String: Double] {
        ["inputTokens": inputTokens, "cacheReadTokens": cacheReadTokens,
         "outputTokens": outputTokens, "totalTokens": totalTokens]
    }
}

private actor CodexSessionTokenCache {
    static let shared = CodexSessionTokenCache()

    private struct Fingerprint: Equatable {
        let size: Int64
        let modifiedAt: TimeInterval
    }

    private struct CacheEntry {
        let fingerprint: Fingerprint
        let usage: LocalSessionTokenUsage?
        let summary: CodexSessionSummary?
        let todayStart: Date
        let todayTokens: Double
        let todayComputed: Bool
    }

    private struct SessionFile {
        let url: URL
        let fingerprint: Fingerprint
    }

    private var cache: [String: CacheEntry] = [:]

    func snapshot(root: URL) -> CodexSessionTokenSnapshot {
        let todayStart = Calendar.current.startOfDay(for: Date())
        guard let files = sessionFiles(root: root), !files.isEmpty else {
            cache.removeAll()
            return CodexSessionTokenSnapshot(
                available: false, sessions: 0, inputTokens: 0,
                cacheReadTokens: 0, outputTokens: 0, totalTokens: 0,
                todayAvailable: false, todayTokens: 0,
                sessionSummaries: []
            )
        }

        let currentPaths = Set(files.map { $0.url.path })
        cache = cache.filter { currentPaths.contains($0.key) }
        for file in files {
            let path = file.url.path
            if let existing = cache[path], existing.fingerprint == file.fingerprint {
                if existing.todayStart != todayStart {
                    cache[path] = CacheEntry(
                        fingerprint: existing.fingerprint,
                        usage: existing.usage,
                        summary: existing.summary,
                        todayStart: todayStart,
                        todayTokens: 0,
                        todayComputed: false
                    )
                }
                continue
            }
            let usage = readLatestUsage(from: file.url, size: file.fingerprint.size)
            let previous = cache[path]
            let hasCurrentDayCache = previous?.todayStart == todayStart
            cache[path] = CacheEntry(
                fingerprint: file.fingerprint,
                usage: usage,
                summary: readSessionSummary(from: file, tokens: usage),
                todayStart: todayStart,
                todayTokens: hasCurrentDayCache ? previous?.todayTokens ?? 0 : 0,
                todayComputed: hasCurrentDayCache ? previous?.todayComputed ?? false : false
            )
        }

        let sessions = cache.values.compactMap(\.usage)
        let input = sessions.reduce(0) { $0 + $1.inputTokens }
        let cached = sessions.reduce(0) { $0 + $1.cacheReadTokens }
        let output = sessions.reduce(0) { $0 + $1.outputTokens }
        let total = sessions.reduce(0) { $0 + $1.totalTokens }
        return CodexSessionTokenSnapshot(
            available: !sessions.isEmpty,
            sessions: sessions.count,
            inputTokens: input,
            cacheReadTokens: cached,
            outputTokens: output,
            totalTokens: total,
            todayAvailable: cache.values.contains { $0.todayStart == todayStart && $0.todayComputed },
            todayTokens: cache.values.reduce(0) { $0 + $1.todayTokens },
            sessionSummaries: files.compactMap { cache[$0.url.path]?.summary }
        )
    }

    func todaySnapshot(root: URL) -> TodayTokenUsage {
        let todayStart = Calendar.current.startOfDay(for: Date())
        guard let files = sessionFiles(root: root), !files.isEmpty else {
            cache.removeAll()
            return TodayTokenUsage(available: false, totalTokens: 0)
        }

        let currentPaths = Set(files.map { $0.url.path })
        cache = cache.filter { currentPaths.contains($0.key) }
        for file in files {
            let path = file.url.path
            let existing = cache[path]
            if let existing, existing.fingerprint == file.fingerprint,
               existing.todayStart == todayStart, existing.todayComputed { continue }

            let currentEntry = existing.flatMap { $0.fingerprint == file.fingerprint ? $0 : nil }
            let usage = currentEntry?.usage ?? readLatestUsage(from: file.url, size: file.fingerprint.size)
            let summary = currentEntry?.summary ?? readSessionSummary(from: file, tokens: usage)
            let tokens = file.fingerprint.modifiedAt >= todayStart.timeIntervalSince1970
                ? readTodayUsage(from: file.url, start: todayStart) : 0
            cache[path] = CacheEntry(
                fingerprint: file.fingerprint,
                usage: usage,
                summary: summary,
                todayStart: todayStart,
                todayTokens: tokens,
                todayComputed: true
            )
        }

        return TodayTokenUsage(
            available: !files.isEmpty,
            totalTokens: cache.values.reduce(0) { $0 + $1.todayTokens }
        )
    }

    func sessionDetail(root: URL, id: String) -> [String: Any]? {
        guard id.range(of: "^[A-Za-z0-9_-]{1,160}$", options: .regularExpression) != nil,
              let files = sessionFiles(root: root),
              let file = files.first(where: { $0.url.deletingPathExtension().lastPathComponent == id }) else { return nil }
        var messages: [[String: Any]] = []
        forEachRecordLine(at: file.url, maximumRecordSize: 16 * 1024 * 1024) { line in
            guard let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let payload = record["payload"] as? [String: Any],
                  payload["type"] as? String == "message",
                  let role = payload["role"] as? String,
                  role == "user" || role == "assistant" else { return }
            if role == "assistant", payload["phase"] as? String != "final_answer" { return }
            guard let content = payload["content"] as? [[String: Any]] else { return }
            let allowedTypes = role == "user" ? Set(["text", "input_text"]) : Set(["text", "output_text"])
            let text = content.compactMap { block -> String? in
                guard let type = block["type"] as? String, allowedTypes.contains(type) else { return nil }
                return block["text"] as? String
            }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            appendTranscriptMessage(&messages, role: role, text: text,
                                    timestamp: record["timestamp"] as? String)
        }
        let usage = readLatestUsage(from: file.url, size: file.fingerprint.size)
        let project = projectName(in: file.url)
        return [
            "id": id,
            "title": messages.first(where: { $0["role"] as? String == "user" })?["text"] as? String ?? "会话详情",
            "project": project,
            "updatedAt": file.fingerprint.modifiedAt,
            "messages": messages,
            "tokensAvailable": usage != nil,
            "tokens": usage?.dictionary ?? [:]
        ]
    }

    private func readSessionSummary(from file: SessionFile,
                                   tokens: LocalSessionTokenUsage?) -> CodexSessionSummary? {
        autoreleasepool {
            guard let handle = try? FileHandle(forReadingFrom: file.url) else { return nil }
            defer { try? handle.close() }
            let data = (try? handle.read(upToCount: 512 * 1024)) ?? Data()
            var title: String?
            var cwd: String?
            for line in data.split(separator: 0x0A) {
                guard let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let payload = record["payload"] as? [String: Any] else { continue }
                if payload["type"] as? String == "session_meta" {
                    cwd = payload["cwd"] as? String
                } else if payload["type"] as? String == "message",
                          payload["role"] as? String == "user",
                          let content = payload["content"] as? [[String: Any]] {
                    title = content.compactMap { block -> String? in
                        guard let type = block["type"] as? String, type == "text" || type == "input_text" else { return nil }
                        return block["text"] as? String
                    }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                    if let title, !title.isEmpty { break }
                }
            }
            let cleanTitle = (title?.isEmpty == false ? title! : "未命名会话")
            return CodexSessionSummary(
                id: file.url.deletingPathExtension().lastPathComponent,
                title: String(cleanTitle.prefix(100)),
                project: cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "ChatGPT",
                updatedAt: file.fingerprint.modifiedAt,
                tokens: tokens
            )
        }
    }

    private func sessionFiles(root: URL) -> [SessionFile]? {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var files: [SessionFile] = []
        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let size = values.fileSize, size > 0 else { continue }
            let modifiedAt = values.contentModificationDate?.timeIntervalSince1970 ?? 0
            files.append(SessionFile(
                url: url,
                fingerprint: Fingerprint(size: Int64(size), modifiedAt: modifiedAt)
            ))
        }
        return files.sorted {
            if $0.fingerprint.modifiedAt == $1.fingerprint.modifiedAt {
                return $0.url.path > $1.url.path
            }
            return $0.fingerprint.modifiedAt > $1.fingerprint.modifiedAt
        }.prefix(200).map { $0 }
    }

    private func readLatestUsage(from file: URL, size: Int64) -> LocalSessionTokenUsage? {
        autoreleasepool {
            guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
            defer { try? handle.close() }
            let tailSize: Int64 = 384 * 1024
            let offset = max(0, size - tailSize)
            try? handle.seek(toOffset: UInt64(offset))
            let data = (try? handle.readToEnd()) ?? Data()
            for line in data.split(separator: 0x0A).reversed() {
                guard let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let payload = record["payload"] as? [String: Any],
                      payload["type"] as? String == "token_count",
                      let info = payload["info"] as? [String: Any],
                      let usage = info["total_token_usage"] as? [String: Any] else { continue }
                let reportedInput = number(usage["input_tokens"])
                let cached = number(usage["cached_input_tokens"])
                let output = number(usage["output_tokens"])
                let reportedTotal = number(usage["total_tokens"])
                return LocalSessionTokenUsage(
                    inputTokens: max(0, reportedInput - cached),
                    cacheReadTokens: cached,
                    outputTokens: output,
                    totalTokens: reportedTotal > 0 ? reportedTotal : reportedInput + output
                )
            }
            return nil
        }
    }

    private func readTodayUsage(from file: URL, start: Date) -> Double {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return 0 }
        defer { try? handle.close() }
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? .distantFuture
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standardFormatter = ISO8601DateFormatter()
        standardFormatter.formatOptions = [.withInternetDateTime]
        let tokenCountMarker = Data("token_count".utf8)
        let chunkSize = 256 * 1024
        let maxRecordSize = 2 * 1024 * 1024
        var pending = Data()
        var skippingOversizedRecord = false
        var total = 0.0

        func tokens(in line: Data) -> Double {
            guard line.range(of: tokenCountMarker) != nil else { return 0 }
            return autoreleasepool {
                guard let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let timestamp = record["timestamp"] as? String,
                      let payload = record["payload"] as? [String: Any],
                      payload["type"] as? String == "token_count",
                      let info = payload["info"] as? [String: Any],
                      let usage = info["last_token_usage"] as? [String: Any] else { return 0 }
                let date = fractionalFormatter.date(from: timestamp) ?? standardFormatter.date(from: timestamp)
                guard let date, date >= start, date < end else { return 0 }
                let reportedInput = number(usage["input_tokens"])
                let output = number(usage["output_tokens"])
                let reportedTotal = number(usage["total_tokens"])
                return reportedTotal > 0 ? reportedTotal : max(0, reportedInput) + output
            }
        }

        while true {
            let chunk: Data
            do {
                guard let next = try handle.read(upToCount: chunkSize), !next.isEmpty else { break }
                chunk = next
            } catch {
                break
            }

            if skippingOversizedRecord {
                guard let newline = chunk.firstIndex(of: 0x0A) else { continue }
                skippingOversizedRecord = false
                let remainderStart = chunk.index(after: newline)
                if remainderStart < chunk.endIndex {
                    pending.append(contentsOf: chunk[remainderStart...])
                }
            } else {
                pending.append(chunk)
            }

            var searchStart = pending.startIndex
            var consumedThrough = pending.startIndex
            while searchStart < pending.endIndex,
                  let newline = pending[searchStart..<pending.endIndex].firstIndex(of: 0x0A) {
                if consumedThrough < newline {
                    total += tokens(in: Data(pending[consumedThrough..<newline]))
                }
                consumedThrough = pending.index(after: newline)
                searchStart = consumedThrough
            }
            if consumedThrough > pending.startIndex {
                pending.removeSubrange(pending.startIndex..<consumedThrough)
            }
            if pending.count > maxRecordSize {
                pending.removeAll(keepingCapacity: true)
                skippingOversizedRecord = true
            }
        }

        if !skippingOversizedRecord, !pending.isEmpty {
            total += tokens(in: pending)
        }
        return total
    }

    private func number(_ value: Any?) -> Double {
        guard let number = value as? NSNumber, number.doubleValue.isFinite else { return 0 }
        return number.doubleValue
    }

    private func appendTranscriptMessage(_ messages: inout [[String: Any]], role: String,
                                         text: String, timestamp: String?) {
        let boundedText = text.count > 16_000 ? String(text.prefix(16_000)) + "\n…（内容已截断）" : text
        messages.append(["role": role, "text": boundedText, "timestamp": timestamp ?? ""])
        if messages.count > 120 { messages.removeFirst(messages.count - 120) }
    }

    private func forEachRecordLine(at url: URL, maximumRecordSize: Int,
                                   process: (Data) -> Void) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        let chunkSize = 256 * 1024
        var pending = Data()
        var skippingOversizedRecord = false

        while true {
            let chunk: Data
            do {
                guard let next = try handle.read(upToCount: chunkSize), !next.isEmpty else { break }
                chunk = next
            } catch {
                break
            }
            if skippingOversizedRecord {
                guard let newline = chunk.firstIndex(of: 0x0A) else { continue }
                skippingOversizedRecord = false
                let remainderStart = chunk.index(after: newline)
                if remainderStart < chunk.endIndex { pending.append(contentsOf: chunk[remainderStart...]) }
            } else {
                pending.append(chunk)
            }

            var searchStart = pending.startIndex
            var consumedThrough = pending.startIndex
            while searchStart < pending.endIndex,
                  let newline = pending[searchStart..<pending.endIndex].firstIndex(of: 0x0A) {
                if consumedThrough < newline {
                    let line = Data(pending[consumedThrough..<newline])
                    autoreleasepool { process(line) }
                }
                consumedThrough = pending.index(after: newline)
                searchStart = consumedThrough
            }
            if consumedThrough > pending.startIndex {
                pending.removeSubrange(pending.startIndex..<consumedThrough)
            }
            if pending.count > maximumRecordSize {
                pending.removeAll(keepingCapacity: true)
                skippingOversizedRecord = true
            }
        }
        if !skippingOversizedRecord, !pending.isEmpty {
            autoreleasepool { process(pending) }
        }
    }

    private func projectName(in url: URL) -> String {
        autoreleasepool {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return "ChatGPT" }
            defer { try? handle.close() }
            let data = (try? handle.read(upToCount: 512 * 1024)) ?? Data()
            for line in data.split(separator: 0x0A) {
                guard let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let payload = record["payload"] as? [String: Any],
                      payload["type"] as? String == "session_meta",
                      let cwd = payload["cwd"] as? String else { continue }
                return URL(fileURLWithPath: cwd).lastPathComponent
            }
            return "ChatGPT"
        }
    }
}

final class DeepSeekCredentials {
    static let shared = DeepSeekCredentials()

    func read() -> String? {
        readHarnessToken()
    }

    private func readHarnessToken() -> String? {
        let file = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".dsh/.credentials.yaml")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let expectedPath = [
            "records", "deepseek-account-platform/default", "payload", "token"
        ]
        var parents: [(indent: Int, key: String)] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let indent = rawLine.prefix(while: { $0 == " " }).count
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"),
                  let separator = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            let rawValue = String(line[line.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
            parents.removeAll { $0.indent >= indent }
            let path = parents.map(\.key) + [key]
            if path == expectedPath {
                var value = rawValue
                if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                    value.removeFirst()
                    value.removeLast()
                } else if value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 {
                    value.removeFirst()
                    value.removeLast()
                } else if let comment = value.firstIndex(of: "#") {
                    value = String(value[..<comment]).trimmingCharacters(in: .whitespaces)
                }
                return value.count >= 32 ? value : nil
            }
            if rawValue.isEmpty { parents.append((indent, key)) }
        }
        return nil
    }

}

private actor DeepSeekTodayTokenCache {
    static let shared = DeepSeekTodayTokenCache()

    private struct Fingerprint: Equatable {
        let size: Int
        let modifiedAt: TimeInterval
    }

    private struct Entry {
        let fingerprint: Fingerprint
        let dayStart: Date
        let tokens: Double
    }

    private var cache: [String: Entry] = [:]

    func snapshot(root: URL, dayStart: Date) -> TodayTokenUsage {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
        ) else { return TodayTokenUsage(available: false, totalTokens: 0) }

        var files: [(url: URL, fingerprint: Fingerprint)] = []
        while let url = enumerator.nextObject() as? URL {
            guard url.lastPathComponent == "session.v4.jsonl.zstd",
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true, let size = values.fileSize else { continue }
            files.append((url, Fingerprint(
                size: size,
                modifiedAt: values.contentModificationDate?.timeIntervalSince1970 ?? 0
            )))
        }

        let paths = Set(files.map { $0.url.path })
        cache = cache.filter { paths.contains($0.key) }
        for file in files {
            let path = file.url.path
            if let cached = cache[path], cached.fingerprint == file.fingerprint,
               cached.dayStart == dayStart { continue }
            if file.fingerprint.modifiedAt < dayStart.timeIntervalSince1970 {
                cache[path] = Entry(fingerprint: file.fingerprint, dayStart: dayStart, tokens: 0)
                continue
            }
            guard let tokens = todayTokenTotal(at: file.url, dayStart: dayStart) else {
                cache.removeValue(forKey: path)
                continue
            }
            cache[path] = Entry(
                fingerprint: file.fingerprint,
                dayStart: dayStart,
                tokens: tokens
            )
        }

        let availableEntries = files.compactMap { cache[$0.url.path] }
        return TodayTokenUsage(
            available: !availableEntries.isEmpty,
            totalTokens: availableEntries.reduce(0) { $0 + $1.tokens }
        )
    }

    private func todayTokenTotal(at url: URL, dayStart: Date) -> Double? {
        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? .distantFuture
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standardFormatter = ISO8601DateFormatter()
        standardFormatter.formatOptions = [.withInternetDateTime]
        var total = 0.0
        let succeeded = forEachZstdRecordLine(at: url, maximumRecordSize: 2 * 1024 * 1024) { line in
            guard let entry = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  entry["type"] as? String == "assistant/message",
                  let timestamp = eventDate(entry["time"], fractional: fractionalFormatter,
                                            standard: standardFormatter),
                  timestamp >= dayStart, timestamp < dayEnd,
                  let payload = entry["data"] as? [String: Any],
                  let usage = payload["usage"] as? [String: Any] else { return }
            let reportedTotal = number(usage["totalTokens"])
            total += reportedTotal > 0
                ? reportedTotal
                : number(usage["inputTokens"]) + number(usage["cacheReadTokens"])
                    + number(usage["outputTokens"])
        }
        return succeeded ? total : nil
    }

    private func eventDate(_ value: Any?, fractional: ISO8601DateFormatter,
                           standard: ISO8601DateFormatter) -> Date? {
        if let number = value as? NSNumber {
            let timestamp = number.doubleValue
            return Date(timeIntervalSince1970: timestamp > 10_000_000_000 ? timestamp / 1000 : timestamp)
        }
        guard let string = value as? String else { return nil }
        return fractional.date(from: string) ?? standard.date(from: string)
    }

    private func number(_ value: Any?) -> Double {
        guard let number = value as? NSNumber, number.doubleValue.isFinite else { return 0 }
        return number.doubleValue
    }
}

final class UsageProvider {
    private let redirectDelegate = NoRedirectDelegate()
    private lazy var session = URLSession(configuration: .ephemeral, delegate: redirectDelegate, delegateQueue: nil)

    func snapshot(availableTools: ToolAvailability) async -> [String: Any] {
        async let codexData = codexSnapshot(enabled: availableTools.codex)
        async let deepSeekData = deepSeekSnapshot(enabled: availableTools.deepSeek)
        return [
            "updatedAt": ISO8601DateFormatter().string(from: Date()),
            "tools": availableTools.dictionary,
            "codex": await codexData,
            "deepseek": await deepSeekData,
            "kimi": [
                "available": false,
                "sessionDetected": false,
                "sessions": [],
                "sessionsReason": "当前 Kimi 本机用量读取路径不提供对话历史",
                "monthly": NSNull(),
                "fiveHour": NSNull(),
                "codeFiveHour": NSNull(),
                "codeWeekly": NSNull(),
                "tokens": [
                    "available": false, "sessions": 0, "inputTokens": 0,
                    "cacheReadTokens": 0, "outputTokens": 0, "totalTokens": 0,
                    "reason": "Kimi 会员额度接口不提供 Token 分项统计"
                ],
                "error": ""
            ]
        ]
    }

    func todayTokenSnapshot(availableTools: ToolAvailability) async -> [String: Any] {
        async let codexUsage = codexTodayUsage(enabled: availableTools.codex)
        async let deepSeekUsage = deepSeekTodayUsage(enabled: availableTools.deepSeek)
        let codex = await codexUsage
        let deepSeek = await deepSeekUsage
        return [
            "codex": ["todayAvailable": codex.available, "todayTokens": codex.totalTokens],
            "deepseek": ["todayAvailable": deepSeek.available, "todayTokens": deepSeek.totalTokens]
        ]
    }

    private func codexTodayUsage(enabled: Bool) async -> TodayTokenUsage {
        guard enabled else { return TodayTokenUsage(available: false, totalTokens: 0) }
        let codexHome = ProcessInfo.processInfo.environment["DSH_CODEX_USAGE_HOME"]
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex").path
        return await CodexSessionTokenCache.shared.todaySnapshot(
            root: URL(fileURLWithPath: codexHome).appendingPathComponent("sessions")
        )
    }

    private func deepSeekTodayUsage(enabled: Bool) async -> TodayTokenUsage {
        guard enabled else { return TodayTokenUsage(available: false, totalTokens: 0) }
        return await DeepSeekTodayTokenCache.shared.snapshot(
            root: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".dsh/sessions"),
            dayStart: Calendar.current.startOfDay(for: Date())
        )
    }

    private func codexSnapshot(enabled: Bool) async -> [String: Any] {
        guard enabled else {
            return [
                "installed": false, "available": false, "source": "none",
                "primary": NSNull(), "weekly": NSNull(),
                "tokens": zeroTokens(available: false, sessions: 0),
                "sessions": [], "sessionsReason": ""
            ]
        }
        let codexHome = ProcessInfo.processInfo.environment["DSH_CODEX_USAGE_HOME"]
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex").path
        let sessionSnapshot = await CodexSessionTokenCache.shared.snapshot(
            root: URL(fileURLWithPath: codexHome).appendingPathComponent("sessions")
        )
        let tokenUsage = sessionSnapshot.dictionary
        let sessions = sessionSnapshot.sessionSummaries.map(\.dictionary)
        let sessionsReason = sessions.isEmpty
            ? "未检测到可读取的 ChatGPT 本机会话记录"
            : "按最近活动时间排列 · 点击一条查看发送内容和最终回复"
        guard let auth = readCodexAuth() else {
            return [
                "installed": true, "available": false, "source": "none",
                "error": "未检测到可用的 ChatGPT 本机会话数据",
                "primary": NSNull(), "weekly": NSNull(), "tokens": tokenUsage,
                "sessions": sessions, "sessionsReason": sessionsReason
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
                "tokens": tokenUsage,
                "sessions": sessions, "sessionsReason": sessionsReason,
                "rateLimitReached": limits["limit_reached"] as? Bool ?? false,
                "error": ""
            ]
        } catch {
            if let cached = readCodexSessionUsage() {
                return [
                    "available": true, "source": "session",
                    "email": "", "planType": "",
                    "primary": cached.primary, "weekly": cached.weekly,
                    "tokens": tokenUsage,
                    "sessions": sessions, "sessionsReason": sessionsReason,
                    "rateLimitReached": false,
                    "updatedAt": cached.updatedAt,
                    "error": "实时接口不可用，显示最近的本地会话快照"
                ]
            }
            return [
                "available": false, "source": "none",
                "email": "", "planType": "",
                "primary": NSNull(), "weekly": NSNull(),
                "tokens": tokenUsage,
                "sessions": sessions, "sessionsReason": sessionsReason,
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

    private func deepSeekSnapshot(enabled: Bool) async -> [String: Any] {
        guard enabled else {
            return [
                "installed": false, "credentialAvailable": false, "profile": NSNull(),
                "balanceAvailable": false, "balances": [],
                "officialSpendAvailable": false, "officialSpend": [],
                "tokens": zeroTokens(available: false, sessions: 0), "error": ""
            ]
        }
        var localTokens = readDeepSeekTokenCache()
        localTokens["todayAvailable"] = false
        localTokens["todayTokens"] = 0
        let localSessions = readDeepSeekSessionSummaries()
        guard let token = DeepSeekCredentials.shared.read() else {
            return [
                "credentialAvailable": false, "profile": NSNull(),
                "balanceAvailable": false, "balances": [],
                "officialSpendAvailable": false, "officialSpend": [],
                "tokens": localTokens, "sessions": localSessions,
                "sessionsReason": localSessions.isEmpty
                    ? "未检测到本机 DeepSeek Harness 对话记录"
                    : "按最近活动时间排列 · 点击一条查看发送内容和模型回复",
                "error": ""
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
            "credentialAvailable": true,
            "profile": profile.isEmpty ? NSNull() : profile,
            "balanceAvailable": balanceAvailable,
            "balances": balances,
            "officialSpendAvailable": officialAvailable,
            "officialSpend": officialCosts,
            "tokens": localTokens,
            "sessions": localSessions,
            "sessionsReason": localSessions.isEmpty
                ? "未检测到本机 DeepSeek Harness 对话记录"
                : "按最近活动时间排列 · 点击一条查看发送内容和模型回复",
            "error": balanceAvailable ? "" : "账户摘要暂时不可用"
        ]
    }

    func sessionDetail(provider: String, sessionID: String) async -> [String: Any] {
        if provider == "codex" {
            let codexHome = ProcessInfo.processInfo.environment["DSH_CODEX_USAGE_HOME"]
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex").path
            if let detail = await CodexSessionTokenCache.shared.sessionDetail(
                root: URL(fileURLWithPath: codexHome).appendingPathComponent("sessions"), id: sessionID
            ) { return detail }
        } else if provider == "deepseek", let detail = deepSeekSessionDetail(id: sessionID) {
            return detail
        }
        return ["error": "无法读取这条会话记录"]
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

    private func readDeepSeekSessionSummaries() -> [[String: Any]] {
        let root = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".dsh/storages/session_projcache/sessions")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return [] }
        return files.filter { $0.pathExtension == "json" }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }.prefix(80).compactMap { file in
            guard let data = try? Data(contentsOf: file),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let record = root["record"] as? [String: Any],
                  let rows = record["rows"] as? [String: Any] else { return nil }
            let identity = record["identity"] as? [String: Any] ?? [:]
            let titleRow = rows["title"] as? [String: Any] ?? [:]
            let title = (titleRow["val"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let cwd = identity["cwd"] as? String ?? ""
            let usageRow = rows["tokenUsage"] as? [String: Any] ?? [:]
            let usageValue = usageRow["val"] as? [String: Any] ?? [:]
            let totals = usageValue["totals"] as? [String: Any] ?? [:]
            let input = number(totals["uncachedInputTokens"] ?? totals["inputTokens"])
            let cached = number(totals["cacheReadTokens"])
            let output = number(totals["outputTokens"])
            let modifiedAt = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?
                .timeIntervalSince1970 ?? 0
            let hasTokens = !totals.isEmpty
            return [
                "id": file.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "session-", with: ""),
                "title": title?.isEmpty == false ? String(title!.prefix(100)) : "未命名会话",
                "project": cwd.isEmpty ? "DeepSeek Harness" : URL(fileURLWithPath: cwd).lastPathComponent,
                "updatedAt": modifiedAt,
                "tokensAvailable": hasTokens,
                "tokens": ["inputTokens": input, "cacheReadTokens": cached,
                           "outputTokens": output, "totalTokens": input + cached + output]
            ]
        }
    }

    private func deepSeekSessionDetail(id: String) -> [String: Any]? {
        guard id.range(of: "^[A-Za-z0-9_-]{1,160}$", options: .regularExpression) != nil else { return nil }
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let projection = home.appendingPathComponent(".dsh/storages/session_projcache/sessions/session-\(id).json")
        guard let projectionData = try? Data(contentsOf: projection),
              let projectionRoot = try? JSONSerialization.jsonObject(with: projectionData) as? [String: Any],
              let record = projectionRoot["record"] as? [String: Any] else { return nil }

        let sessionRoot = home.appendingPathComponent(".dsh/sessions", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(at: sessionRoot, includingPropertiesForKeys: nil),
              let log = enumerator.compactMap({ $0 as? URL }).first(where: {
                  $0.lastPathComponent == "session.v4.jsonl.zstd"
                    && $0.deletingLastPathComponent().lastPathComponent == "session-\(id)"
              }) else { return nil }

        var messages: [[String: Any]] = []
        let readSucceeded = forEachZstdRecordLine(at: log, maximumRecordSize: 16 * 1024 * 1024) { line in
            guard let entry = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = entry["type"] as? String else { return }
            if type == "user/message", let payload = entry["data"] as? [String: Any] {
                let content = payload["content"] as? [[String: Any]] ?? []
                let text = content.filter { ($0["type"] as? String) == "text" }
                    .compactMap { $0["text"] as? String }.joined(separator: "\n")
                appendTranscriptMessage(&messages, role: "user", text: text,
                                        timestamp: entry["time"] as? String)
            } else if type == "assistant/message", let payload = entry["data"] as? [String: Any] {
                let message = payload["message"] as? [String: Any] ?? [:]
                let content = message["content"] as? [[String: Any]] ?? []
                let text = content.filter { ($0["type"] as? String) == "text" }
                    .compactMap { $0["text"] as? String }.joined(separator: "\n")
                appendTranscriptMessage(&messages, role: "assistant", text: text,
                                        timestamp: entry["time"] as? String)
            }
        }
        guard readSucceeded else { return nil }
        let rows = record["rows"] as? [String: Any] ?? [:]
        let tokenRow = rows["tokenUsage"] as? [String: Any] ?? [:]
        let tokenValue = tokenRow["val"] as? [String: Any] ?? [:]
        let totals = tokenValue["totals"] as? [String: Any] ?? [:]
        let input = number(totals["uncachedInputTokens"] ?? totals["inputTokens"])
        let cached = number(totals["cacheReadTokens"])
        let output = number(totals["outputTokens"])
        let identity = record["identity"] as? [String: Any] ?? [:]
        let cwd = identity["cwd"] as? String ?? ""
        let titleRow = rows["title"] as? [String: Any] ?? [:]
        let title = titleRow["val"] as? String ?? "会话详情"
        return [
            "id": id, "title": title, "project": cwd.isEmpty ? "DeepSeek Harness" : URL(fileURLWithPath: cwd).lastPathComponent,
            "updatedAt": (try? projection.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?
                .timeIntervalSince1970 ?? 0,
            "messages": messages,
            "tokensAvailable": !totals.isEmpty,
            "tokens": ["inputTokens": input, "cacheReadTokens": cached,
                       "outputTokens": output, "totalTokens": input + cached + output]
        ]
    }

    private func appendTranscriptMessage(_ messages: inout [[String: Any]], role: String,
                                         text: String, timestamp: String?) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let boundedText = text.count > 16_000 ? String(text.prefix(16_000)) + "\n…（内容已截断）" : text
        messages.append(["role": role, "text": boundedText, "timestamp": timestamp ?? ""])
        if messages.count > 120 { messages.removeFirst(messages.count - 120) }
    }

    private func zeroTokens(available: Bool, sessions: Int) -> [String: Any] {
        [
            "available": available, "sessions": sessions, "inputTokens": 0,
            "cacheReadTokens": 0, "cacheWriteTokens": 0, "outputTokens": 0,
            "totalTokens": 0, "source": "本机 DeepSeek Harness 会话投影",
            "reason": available ? "" : "未检测到本机 DeepSeek 会话投影"
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
