// 自动更新的纯逻辑（D76）：版本比较、Release 解析、检查周期。

import Foundation
import Testing
import SysModel

@Suite struct AppUpdateTests {
    @Test func parsesVersions() {
        #expect(AppVersion("v1.2.3") == AppVersion(major: 1, minor: 2, patch: 3))
        #expect(AppVersion("1.0") == AppVersion(major: 1, minor: 0, patch: 0))
        #expect(AppVersion("2") == AppVersion(major: 2, minor: 0, patch: 0))
        #expect(AppVersion("1.1.0-rc1") == nil)
        #expect(AppVersion("1..2") == nil)
        #expect(AppVersion("1.2.3.4") == nil)
        #expect(AppVersion("") == nil)
        #expect(AppVersion("v１.0.0") == nil)
    }

    @Test func comparesVersions() throws {
        let v = { (s: String) throws -> AppVersion in try #require(AppVersion(s)) }
        #expect(try v("1.0.1") > v("1.0.0"))
        #expect(try v("1.10.0") > v("1.9.9"))
        #expect(try v("2.0.0") > v("1.99.99"))
        #expect(try !(v("1.0.0") > v("1.0.0")))
    }

    private static func release(
        tag: String, draft: Bool = false, prerelease: Bool = false, assets: [String]
    ) throws -> GitHubRelease {
        let assetJSON = assets.map {
            #"{"name":"\#($0)","browser_download_url":"https://github.com/o/r/releases/download/\#(tag)/\#($0)","size":42}"#
        }.joined(separator: ",")
        let json = """
            {"tag_name":"\(tag)","html_url":"https://github.com/o/r/releases/tag/\(tag)","body":"notes",
             "draft":\(draft),"prerelease":\(prerelease),"assets":[\(assetJSON)]}
            """
        return try JSONDecoder().decode(GitHubRelease.self, from: Data(json.utf8))
    }

    @Test func offersNewerCompleteRelease() throws {
        let current = try #require(AppVersion("1.0.0"))
        let r = try Self.release(tag: "v1.0.1", assets: ["SysInfo-1.0.1.zip", "SysInfo-1.0.1.zip.sha256"])
        let offer = try #require(UpdateOffer.make(from: r, current: current))
        #expect(offer.version == AppVersion("1.0.1"))
        #expect(offer.archiveURL.lastPathComponent == "SysInfo-1.0.1.zip")
        #expect(offer.checksumURL.lastPathComponent == "SysInfo-1.0.1.zip.sha256")
        #expect(offer.archiveSize == 42)
        #expect(offer.notes == "notes")
    }

    @Test func rejectsSameOlderDraftPrereleaseOrIncomplete() throws {
        let current = try #require(AppVersion("1.0.1"))
        let both = { (tag: String) in ["SysInfo-\(tag.dropFirst()).zip", "SysInfo-\(tag.dropFirst()).zip.sha256"] }
        #expect(UpdateOffer.make(from: try Self.release(tag: "v1.0.1", assets: both("v1.0.1")), current: current) == nil)
        #expect(UpdateOffer.make(from: try Self.release(tag: "v1.0.0", assets: both("v1.0.0")), current: current) == nil)
        #expect(UpdateOffer.make(from: try Self.release(tag: "v1.1.0", draft: true, assets: both("v1.1.0")), current: current) == nil)
        #expect(
            UpdateOffer.make(from: try Self.release(tag: "v1.1.0", prerelease: true, assets: both("v1.1.0")), current: current)
                == nil)
        #expect(UpdateOffer.make(from: try Self.release(tag: "v1.1.0", assets: ["SysInfo-1.1.0.zip"]), current: current) == nil)
        #expect(
            UpdateOffer.make(from: try Self.release(tag: "v1.1.0", assets: ["SysInfo-1.0.9.zip", "SysInfo-1.0.9.zip.sha256"]), current: current)
                == nil)
    }

    @Test func parsesBuildVersionsWithSuffix() throws {
        let rc = try #require(AppVersion(build: "1.1.0-rc1"))
        #expect(rc.isPrerelease)
        #expect(rc < AppVersion(major: 1, minor: 1, patch: 0))
        #expect(rc > AppVersion(major: 1, minor: 0, patch: 9))
        #expect(AppVersion(build: "1.0") == AppVersion(major: 1, minor: 0, patch: 0))
        #expect(AppVersion(build: "1.0.0+5") == AppVersion(major: 1, minor: 0, patch: 0))
        #expect(AppVersion(build: "1.0.0-") == nil)
        #expect(AppVersion(build: "?") == nil)
    }

    /// A29：CI 产物按 MARKETING_VERSION 原文命名，两段版本号时不补成三段。
    @Test func matchesAssetNamesByTagText() throws {
        let current = try #require(AppVersion("1.0.0"))
        let r = try Self.release(tag: "v1.1", assets: ["SysInfo-1.1.zip", "SysInfo-1.1.zip.sha256"])
        let offer = try #require(UpdateOffer.make(from: r, current: current))
        #expect(offer.version == AppVersion("1.1.0"))
        #expect(offer.archiveURL.lastPathComponent == "SysInfo-1.1.zip")
        let rc = try #require(AppVersion(build: "1.1.0-rc1"))
        let final = try Self.release(tag: "v1.1.0", assets: ["SysInfo-1.1.0.zip", "SysInfo-1.1.0.zip.sha256"])
        #expect(UpdateOffer.make(from: final, current: rc) != nil)
        let older = try Self.release(tag: "v1.0.9", assets: ["SysInfo-1.0.9.zip", "SysInfo-1.0.9.zip.sha256"])
        #expect(UpdateOffer.make(from: older, current: rc) == nil)
    }

    @Test func parsesChecksumFiles() {
        let hex = String(repeating: "aB", count: 32)
        #expect(UpdateOffer.parseChecksum("\(hex)  SysInfo-1.0.0.zip\n") == hex.lowercased())
        #expect(UpdateOffer.parseChecksum("abc  SysInfo-1.0.0.zip") == nil)
        #expect(UpdateOffer.parseChecksum("") == nil)
        #expect(UpdateOffer.parseChecksum(String(repeating: "g", count: 64)) == nil)
    }

    @Test func checkIsDuePerFrequency() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(UpdateCheckFrequency.weekly.isDue(lastCheck: nil, now: now))
        #expect(!UpdateCheckFrequency.weekly.isDue(lastCheck: now.addingTimeInterval(-6 * 86_400), now: now))
        #expect(UpdateCheckFrequency.weekly.isDue(lastCheck: now.addingTimeInterval(-7 * 86_400), now: now))
        #expect(UpdateCheckFrequency.daily.isDue(lastCheck: now.addingTimeInterval(-86_400), now: now))
        #expect(!UpdateCheckFrequency.daily.isDue(lastCheck: now.addingTimeInterval(-3_600), now: now))
        #expect(UpdateCheckFrequency.daily.isDue(lastCheck: now.addingTimeInterval(3_600), now: now))
        #expect(!UpdateCheckFrequency.off.isDue(lastCheck: nil, now: now))
    }

    /// D100：自动检查失败后按天重试，成功后回到原周期。
    @Test func retriesDailyAfterFailure() {
        let now = Date(timeIntervalSince1970: 10_000_000)
        let weekAgo = now.addingTimeInterval(-8 * 86_400)
        let f = UpdateCheckFrequency.weekly
        #expect(!f.isDue(lastCheck: weekAgo, lastFailure: now.addingTimeInterval(-3_600), now: now))
        #expect(f.isDue(lastCheck: weekAgo, lastFailure: now.addingTimeInterval(-86_400), now: now))
        #expect(!f.isDue(lastCheck: nil, lastFailure: now.addingTimeInterval(-3_600), now: now))
        #expect(f.isDue(lastCheck: nil, lastFailure: now.addingTimeInterval(-86_400), now: now))
        // 失败早于上次成功：按成功时间算周期。
        let recent = now.addingTimeInterval(-2 * 86_400)
        #expect(!f.isDue(lastCheck: recent, lastFailure: recent.addingTimeInterval(-86_400), now: now))
        #expect(f.isDue(lastCheck: weekAgo, lastFailure: now.addingTimeInterval(3_600), now: now))
        #expect(!UpdateCheckFrequency.off.isDue(lastCheck: nil, lastFailure: weekAgo, now: now))
    }
}
