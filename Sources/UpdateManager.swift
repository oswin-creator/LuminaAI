import Foundation
import AppKit

struct ReleaseItem: Identifiable, Equatable {
    var id: String { version }
    let version: String
    let title: String
    let publishedDate: String
    let notes: String
    let downloadURL: URL
}

enum UpdateStatus: Equatable {
    case idle
    case checking
    case upToDate(recentReleases: [ReleaseItem])
    case available(latest: ReleaseItem, pendingReleases: [ReleaseItem])
    case downloading
    case installing
    case error(String)
}

final class UpdateManager: ObservableObject {
    static let shared = UpdateManager()

    /// Built-in GitHub repository (zero manual configuration required)
    static let githubRepo = "oswin-creator/LuminaAI"
    static let localSignerName = "LuminaAI Local Signer"

    @Published var status: UpdateStatus = .idle
    @Published var showUpdateSheet: Bool = false

    var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.1.1"
    }

    private init() {}

    func checkForUpdates(silent: Bool = false) {
        status = .checking
        let urlString = "https://api.github.com/repos/\(Self.githubRepo)/releases?per_page=10"
        guard let url = URL(string: urlString) else {
            status = .error("更新地址无效")
            return
        }

        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("LuminaAI/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15

        Task {
            do {
                let (data, response) = try await URLSession.shared.data(for: req)
                guard let http = response as? HTTPURLResponse else {
                    throw NSError(domain: "Update", code: -1, userInfo: [NSLocalizedDescriptionKey: "网络响应异常"])
                }
                if http.statusCode == 404 {
                    await MainActor.run {
                        self.status = .upToDate(recentReleases: [])
                        if !silent {
                            ToastHUD.shared.show("当前已是最新版本 (v\(self.currentVersion))")
                        }
                    }
                    return
                }
                guard (200...299).contains(http.statusCode),
                      let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                    throw NSError(domain: "Update", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "检查更新失败 (HTTP \(http.statusCode))"])
                }

                var parsed: [ReleaseItem] = []
                for item in list {
                    if (item["draft"] as? Bool) == true { continue }
                    guard let tagName = item["tag_name"] as? String else { continue }
                    let ver = tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
                    let title = (item["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let rawDate = (item["published_at"] as? String) ?? ""
                    let shortDate = rawDate.count >= 10 ? String(rawDate.prefix(10)) : ""
                    let body = ((item["body"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let notes = body.isEmpty ? "体验优化与问题修复。" : body
                    let assets = (item["assets"] as? [[String: Any]]) ?? []
                    let zipAsset = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true })
                    let dlString = (zipAsset?["browser_download_url"] as? String)
                        ?? (item["html_url"] as? String)
                        ?? "https://github.com/\(Self.githubRepo)/releases/latest"
                    if let dlURL = URL(string: dlString) {
                        parsed.append(ReleaseItem(
                            version: ver,
                            title: (title?.isEmpty == false) ? title! : "v\(ver)",
                            publishedDate: shortDate,
                            notes: notes,
                            downloadURL: dlURL
                        ))
                    }
                }

                let newerReleases = parsed.filter { Self.isVersion($0.version, newerThan: self.currentVersion) }

                await MainActor.run {
                    if let latest = newerReleases.first {
                        self.status = .available(latest: latest, pendingReleases: newerReleases)
                        self.showUpdateSheet = true
                    } else {
                        self.status = .upToDate(recentReleases: Array(parsed.prefix(5)))
                        if !silent {
                            self.showUpdateSheet = true
                        }
                    }
                }
            } catch {
                AppLogger.shared.error("Update check failed: \(error.localizedDescription)")
                await MainActor.run {
                    self.status = .error("检查更新失败：\(error.localizedDescription)")
                    if !silent {
                        self.showUpdateSheet = true
                    }
                }
            }
        }
    }

    /// Downloads the release zip, re-signs with local persistent certificate (preserving TCC permissions!), swaps bundle and relaunches.
    func downloadAndInstall(from url: URL) {
        if !url.pathExtension.lowercased().contains("zip") {
            NSWorkspace.shared.open(url)
            return
        }

        status = .downloading
        Task {
            do {
                let (tempZipURL, _) = try await URLSession.shared.download(from: url)
                let workDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("LuminaAI_Update_\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

                let unzip = Process()
                unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                unzip.arguments = ["-xk", tempZipURL.path, workDir.path]
                try unzip.run()
                unzip.waitUntilExit()

                let contents = try FileManager.default.contentsOfDirectory(at: workDir, includingPropertiesForKeys: nil)
                guard let newAppURL = contents.first(where: { $0.pathExtension == "app" }) else {
                    throw NSError(domain: "Update", code: -2, userInfo: [NSLocalizedDescriptionKey: "更新包中未找到 .app 文件"])
                }

                await MainActor.run { self.status = .installing }

                // Re-sign with persistent local certificate so macOS keeps Accessibility & Screen Recording permissions!
                Self.resignWithLocalCertificateIfAvailable(appURL: newAppURL)

                let currentAppPath = Bundle.main.bundlePath
                let scriptPath = workDir.appendingPathComponent("apply_update.sh").path
                let pid = ProcessInfo.processInfo.processIdentifier
                let script = """
                #!/bin/zsh
                while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
                rm -rf "\(currentAppPath)"
                mv "\(newAppURL.path)" "\(currentAppPath)"
                open "\(currentAppPath)"
                rm -rf "\(workDir.path)"
                """
                try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)

                let runner = Process()
                runner.executableURL = URL(fileURLWithPath: "/bin/zsh")
                runner.arguments = [scriptPath]
                try runner.run()

                await MainActor.run {
                    NSApp.terminate(nil)
                }
            } catch {
                AppLogger.shared.error("Auto-update install failed: \(error.localizedDescription)")
                await MainActor.run {
                    self.status = .error("自动更新失败：\(error.localizedDescription)")
                }
            }
        }
    }

    private static func resignWithLocalCertificateIfAvailable(appURL: URL) {
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        check.arguments = ["find-identity", "-v", "-p", "codesigning"]
        let pipe = Pipe()
        check.standardOutput = pipe
        try? check.run()
        check.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        let signIdentity = out.contains(localSignerName) ? localSignerName : "-"
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        if signIdentity == localSignerName {
            sign.arguments = [
                "--force", "--deep", "--sign", localSignerName,
                "-r=designated => identifier \"com.lumina.ai.assistant\" and certificate leaf[subject.CN] = \"\(localSignerName)\"",
                appURL.path
            ]
        } else {
            sign.arguments = ["--force", "--deep", "--sign", "-", appURL.path]
        }
        try? sign.run()
        sign.waitUntilExit()
        AppLogger.shared.info("Re-signed downloaded update with identity: \(signIdentity)")
    }

    static func isVersion(_ a: String, newerThan b: String) -> Bool {
        let pa = a.split(separator: ".").compactMap { Int($0) }
        let pb = b.split(separator: ".").compactMap { Int($0) }
        let count = max(pa.count, pb.count)
        for i in 0..<count {
            let va = i < pa.count ? pa[i] : 0
            let vb = i < pb.count ? pb[i] : 0
            if va != vb { return va > vb }
        }
        return false
    }
}
