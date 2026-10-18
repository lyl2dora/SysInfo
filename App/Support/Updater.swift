// 自动更新（D76）：按设置的频率查本仓库的 GitHub Releases；出厂每周检查、只提示，用户点了才下载安装。
// 只在日用版（zone.lyl.sysinfo 的 Release 构建）启用：Debug 版和开销测量用的 .dev 构建都不联网。
// 出站目标只有 api.github.com（查最新版本）和 Release 给出的下载地址（github.com 及其重定向的下载域），不上传本机信息。
//
// 安装前逐项校验，任何一项不通过就放弃：
//   1. 发布包的 SHA-256 与同一 Release 的 .sha256 文件一致；
//   2. 代码签名有效，Team ID 为 D8MFB2YNN3、Bundle ID 为 zone.lyl.sysinfo；
//   3. Gatekeeper 评估通过（spctl，已公证）；
//   4. 包里的版本号与 Release 一致，且比当前版本新。
// 通过后用新包原子替换 /Applications 下的自己，等本进程退出后重新打开。

import AppKit
import CryptoKit
import Observation
import Security
import SysModel
import os

@Observable
final class Updater {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(UpdateOffer)
        case downloading(UpdateOffer)
        case installing(UpdateOffer)
        case failed(String)
    }

    static let repository = "lyl2dora/SysInfo"
    static let releaseBundleIdentifier = "zone.lyl.sysinfo"
    static let teamIdentifier = "D8MFB2YNN3"
    private static let lastCheckKey = "update.lastCheck"

    private(set) var state: State = .idle
    private(set) var lastCheck: Date?
    /// 本构建是否检查更新：只有日用版（D76）。
    let isEnabled: Bool
    /// 能否就地替换：从 /Applications 运行，且有写权限。不能时只提示，附 Release 页面链接。
    let canInstall: Bool
    /// 正从隔离位置运行（App Translocation）：提示用访达移入「应用程序」。
    let isTranslocated: Bool

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let bundleURL: URL

    init(settings: AppSettings, defaults: UserDefaults = .standard, bundle: Bundle = .main) {
        self.settings = settings
        self.defaults = defaults
        bundleURL = bundle.bundleURL.resolvingSymlinksInPath()
        isEnabled = !BuildInfo.isDebug && bundle.bundleIdentifier == Self.releaseBundleIdentifier
        isTranslocated = LoginItemModel.isTranslocated(bundleURL.path)
        let parent = bundleURL.deletingLastPathComponent().path
        canInstall =
            isEnabled && bundleURL.path.hasPrefix("/Applications/")
            && FileManager.default.isWritableFile(atPath: parent) && FileManager.default.isWritableFile(atPath: bundleURL.path)
        let stamp = defaults.double(forKey: Self.lastCheckKey)
        lastCheck = stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
    }

    var availableOffer: UpdateOffer? {
        switch state {
        case .available(let offer), .downloading(let offer), .installing(let offer): offer
        default: nil
        }
    }

    var isBusy: Bool {
        switch state {
        case .checking, .downloading, .installing: true
        default: false
        }
    }

    /// 启动后约 1 分钟查一次是否到期，之后每小时看一次；到期才真的联网。
    func start() {
        guard isEnabled, timer == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in self?.checkIfDue() }
        let timer = Timer(timeInterval: 3_600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
        timer.tolerance = 600
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func checkIfDue() {
        guard isEnabled, !isBusy, settings.updateFrequency.isDue(lastCheck: lastCheck, now: .now) else { return }
        checkNow(automatic: true)
    }

    /// 「立即检查」或到期检查。自动检查发现新版本、且用户选了自动安装时，接着下载安装。
    func checkNow(automatic: Bool = false) {
        guard isEnabled, !isBusy else { return }
        state = .checking
        let current = AppVersion(BuildInfo.version) ?? AppVersion(major: 0, minor: 0, patch: 0)
        Task {
            do {
                let offer = try await UpdateClient.latestOffer(repository: Self.repository, current: current)
                let now = Date.now
                lastCheck = now
                defaults.set(now.timeIntervalSince1970, forKey: Self.lastCheckKey)
                if let offer {
                    state = .available(offer)
                    Log.app.info("发现新版本 \(offer.version.description, privacy: .public)")
                    if automatic, settings.updateAutoInstall, canInstall { install() }
                } else {
                    state = .upToDate
                }
            } catch {
                state = .failed(String(localized: "检查更新失败：\(error.localizedDescription)"))
                Log.app.error("检查更新失败：\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func install() {
        guard canInstall, case .available(let offer) = state else { return }
        state = .downloading(offer)
        let target = bundleURL
        Task {
            do {
                let staged = try await UpdateInstaller.downloadAndVerify(
                    offer: offer, bundleIdentifier: Self.releaseBundleIdentifier, teamIdentifier: Self.teamIdentifier)
                state = .installing(offer)
                try await UpdateInstaller.replace(target: target, with: staged)
                Log.app.info("已安装 \(offer.version.description, privacy: .public)，重新启动")
                UpdateInstaller.relaunch(at: target)
                NSApp.terminate(nil)
            } catch {
                state = .failed(String(localized: "更新没有安装：\(error.localizedDescription)"))
                Log.app.error("更新没有安装：\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func openReleasePage() {
        let url = availableOffer?.releasePageURL ?? URL(string: "https://github.com/\(Self.repository)/releases")!
        NSWorkspace.shared.open(url)
    }
}

/// 查最新 Release（只读公开接口，不带任何凭据与本机信息）。
nonisolated enum UpdateClient {
    struct HTTPError: LocalizedError {
        let status: Int
        var errorDescription: String? { String(localized: "服务器返回 \(status)") }
    }

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 600
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    static func request(_ url: URL, accept: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        // GitHub API 要求带 User-Agent；只有产品名和版本号。
        request.setValue("SysInfo/\(BuildInfo.version)", forHTTPHeaderField: "User-Agent")
        return request
    }

    @concurrent static func latestOffer(repository: String, current: AppVersion) async throws -> UpdateOffer? {
        let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
        let (data, response) = try await session.data(for: request(url, accept: "application/vnd.github+json"))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil }  // 还没有任何正式 Release
        guard status == 200 else { throw HTTPError(status: status) }
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        return UpdateOffer.make(from: release, current: current)
    }
}

/// 下载、校验、替换与重启。
nonisolated enum UpdateInstaller {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// 暂存目录：~/Library/Caches/<bundle id>/Update；每次安装前清空。
    static func stagingDirectory() throws -> URL {
        let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return caches.appending(path: BuildInfo.bundleIdentifier).appending(path: "Update")
    }

    /// 下载发布包并逐项校验，返回暂存的新 SysInfo.app。
    @concurrent static func downloadAndVerify(
        offer: UpdateOffer, bundleIdentifier: String, teamIdentifier: String
    ) async throws -> URL {
        let fm = FileManager.default
        let dir = try stagingDirectory()
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        // 1. SHA-256
        let (checksumData, checksumResponse) = try await UpdateClient.session.data(
            for: UpdateClient.request(offer.checksumURL, accept: "application/octet-stream"))
        guard (checksumResponse as? HTTPURLResponse)?.statusCode == 200,
            let expected = UpdateOffer.parseChecksum(String(decoding: checksumData, as: UTF8.self))
        else { throw Failure(message: String(localized: "读不到校验文件")) }
        let (downloaded, archiveResponse) = try await UpdateClient.session.download(
            for: UpdateClient.request(offer.archiveURL, accept: "application/octet-stream"))
        guard (archiveResponse as? HTTPURLResponse)?.statusCode == 200 else {
            throw Failure(message: String(localized: "下载失败"))
        }
        let archive = dir.appending(path: "SysInfo-\(offer.version).zip")
        try fm.moveItem(at: downloaded, to: archive)
        let digest = SHA256.hash(data: try Data(contentsOf: archive, options: .mappedIfSafe))
        let actual = digest.map { String(format: "%02x", $0) }.joined()
        guard actual == expected else { throw Failure(message: String(localized: "发布包的校验值不一致")) }

        // 解压
        let extracted = dir.appending(path: "extracted")
        try run("/usr/bin/ditto", ["-x", "-k", archive.path, extracted.path], failure: String(localized: "解压失败"))
        let app = extracted.appending(path: "SysInfo.app")
        guard fm.fileExists(atPath: app.path) else { throw Failure(message: String(localized: "发布包里没有 SysInfo.app")) }

        // 2. 代码签名：Team ID 与 Bundle ID
        try verifySignature(of: app, bundleIdentifier: bundleIdentifier, teamIdentifier: teamIdentifier)
        // 3. Gatekeeper（已公证）
        try run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path], failure: String(localized: "没有通过 Gatekeeper 评估"))
        // 4. 版本号
        let info = NSDictionary(contentsOf: app.appending(path: "Contents/Info.plist"))
        guard let text = info?["CFBundleShortVersionString"] as? String, AppVersion(text) == offer.version else {
            throw Failure(message: String(localized: "发布包的版本号与 Release 不一致"))
        }
        return app
    }

    static func verifySignature(of app: URL, bundleIdentifier: String, teamIdentifier: String) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw Failure(message: String(localized: "读不到发布包的签名"))
        }
        let text =
            "anchor apple generic and identifier \"\(bundleIdentifier)\" and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else {
            throw Failure(message: String(localized: "签名要求无效"))
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else {
            throw Failure(message: String(localized: "发布包的签名不是 SysInfo 的开发者"))
        }
    }

    /// 用新包原子替换当前的 SysInfo.app（同一卷上交换，失败时原包不动）。
    @concurrent static func replace(target: URL, with staged: URL) async throws {
        _ = try FileManager.default.replaceItemAt(target, withItemAt: staged)
        try? FileManager.default.removeItem(at: try stagingDirectory())
    }

    /// 等本进程退出后重新打开（单实例判定在新进程里进行，D48）。
    static func relaunch(at app: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c", "while kill -0 \"$0\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$1\"",
            String(ProcessInfo.processInfo.processIdentifier), app.path,
        ]
        try? process.run()
    }

    private static func run(_ tool: String, _ arguments: [String], failure: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure(message: failure) }
    }
}
