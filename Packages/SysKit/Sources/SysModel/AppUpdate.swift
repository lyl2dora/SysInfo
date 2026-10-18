// 自动更新的纯逻辑（D76）：版本比较、GitHub Release 解析、检查周期。网络、校验与替换在 app 的 Updater 里。

import Foundation

/// 「主.次.修订」三段版本号；tag 可以带前缀 v。带预发布后缀（如 1.1.0-rc1）的不算正式版本，解析为 nil。
public struct AppVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public init?(_ text: String) {
        var s = Substring(text.trimmingCharacters(in: .whitespaces))
        if s.first == "v" || s.first == "V" { s = s.dropFirst() }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber), let n = Int(part) else { return nil }
            numbers.append(n)
        }
        while numbers.count < 3 { numbers.append(0) }
        self.init(major: numbers[0], minor: numbers[1], patch: numbers[2])
    }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }
}

/// GitHub `GET /repos/{owner}/{repo}/releases/latest` 的返回里用到的字段。
public struct GitHubRelease: Decodable, Sendable {
    public struct Asset: Decodable, Sendable {
        public let name: String
        public let browserDownloadURL: URL
        public let size: Int

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
            case size
        }
    }

    public let tagName: String
    public let htmlURL: URL
    public let body: String?
    public let draft: Bool
    public let prerelease: Bool
    public let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case body, draft, prerelease, assets
    }
}

/// 一个可以安装的新版本：发布包（SysInfo-<版本>.zip）与它的 SHA-256 文件（D74 的 CI 产物）。
public struct UpdateOffer: Equatable, Sendable {
    public let version: AppVersion
    public let archiveURL: URL
    public let archiveSize: Int
    public let checksumURL: URL
    public let releasePageURL: URL
    public let notes: String

    /// 比当前版本新、且产物齐全时返回；草稿、预发布、版本号不规范或缺产物时为 nil。
    public static func make(from release: GitHubRelease, current: AppVersion) -> UpdateOffer? {
        guard !release.draft, !release.prerelease, let version = AppVersion(release.tagName), version > current else {
            return nil
        }
        let archiveName = "SysInfo-\(version).zip"
        guard let archive = release.assets.first(where: { $0.name == archiveName }),
            let checksum = release.assets.first(where: { $0.name == archiveName + ".sha256" })
        else { return nil }
        return UpdateOffer(
            version: version, archiveURL: archive.browserDownloadURL, archiveSize: archive.size,
            checksumURL: checksum.browserDownloadURL, releasePageURL: release.htmlURL, notes: release.body ?? "")
    }

    /// `shasum -a 256` 输出的第一个字段（64 位十六进制，小写）；格式不对时为 nil。
    public static func parseChecksum(_ text: String) -> String? {
        guard let token = text.split(whereSeparator: \.isWhitespace).first else { return nil }
        let hex = token.lowercased()
        guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        return hex
    }
}

/// 检查更新的频率（D76：出厂每周）。
public enum UpdateCheckFrequency: String, CaseIterable, Identifiable, Sendable {
    case off
    case daily
    case weekly

    public var id: String { rawValue }

    public var interval: TimeInterval? {
        switch self {
        case .off: nil
        case .daily: 86_400
        case .weekly: 7 * 86_400
        }
    }

    /// 是否到了该检查的时候：从没检查过，或距上次检查已满一个周期。系统时钟往回拨（上次检查在未来）时也视为到期。
    public func isDue(lastCheck: Date?, now: Date) -> Bool {
        guard let interval else { return false }
        guard let lastCheck else { return true }
        let elapsed = now.timeIntervalSince(lastCheck)
        return elapsed < 0 || elapsed >= interval
    }
}
