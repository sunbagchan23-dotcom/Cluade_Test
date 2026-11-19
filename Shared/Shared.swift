import Foundation

/// 본 앱과 방송 확장이 함께 쓰는 설정·경로·로그 기록 코드.
enum Shared {
    static let defaultGroupID = "group.com.sunbag.screenocr"
    static let logFileName = "ocr_log.jsonl"

    /// 사이드로딩 도구(AltStore, Sideloadly)는 무료 계정으로 서명할 때
    /// App Group ID 뒤에 팀 ID 등을 붙여 바꾸는 경우가 있다.
    /// 그래서 하드코딩 대신 실제 서명 프로필(embedded.mobileprovision)에서 읽는다.
    static let provisionedGroups: [String] = readProvisionedGroups() ?? []

    static let appGroupID: String = {
        if let g = provisionedGroups.first(where: { $0.hasPrefix(defaultGroupID) }) { return g }
        if let g = provisionedGroups.first { return g }
        if let g = Bundle.main.object(forInfoDictionaryKey: "AppGroupID") as? String, !g.isEmpty { return g }
        return defaultGroupID
    }()

    /// App Group 컨테이너. 권한이 없으면 nil.
    static let groupContainer: URL? =
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)

    static var isGroupAvailable: Bool { groupContainer != nil }

    /// 앱 버전 (예: "0.2.2 (5)"). 숫자는 CHANGELOG.md와 GitHub 태그·Release 이름과 같다.
    /// 괄호 안은 클라우드 빌드 번호.
    static var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }

    /// 로그 파일 위치. App Group이 안 되면 자기 Documents 폴더(공유 안 됨).
    static var logURL: URL {
        let base = groupContainer
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(logFileName)
    }

    static var defaults: UserDefaults {
        (isGroupAvailable ? UserDefaults(suiteName: appGroupID) : nil) ?? .standard
    }

    private static func readProvisionedGroups() -> [String]? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex)
        else { return nil }
        let plistData = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              let ent = plist["Entitlements"] as? [String: Any],
              let groups = ent["com.apple.security.application-groups"] as? [String]
        else { return nil }
        return groups
    }
}

/// 사용자가 본 앱에서 바꾸는 설정. 확장은 방송 시작 시 한 번 읽는다.
struct OCRSettings {
    var interval: Double      // 초
    var scale: Double         // 0.3~1.0, 1.0이면 원본 그대로
    var languageCorrection: Bool

    static func load() -> OCRSettings {
        let d = Shared.defaults
        let i = d.double(forKey: "interval")
        let s = d.double(forKey: "scale")
        return OCRSettings(
            interval: i > 0 ? i : 5,
            scale: s > 0 ? s : 0.6,
            languageCorrection: d.bool(forKey: "languageCorrection")
        )
    }

    func save() {
        let d = Shared.defaults
        d.set(interval, forKey: "interval")
        d.set(scale, forKey: "scale")
        d.set(languageCorrection, forKey: "languageCorrection")
    }
}

/// 로그 한 줄 (JSON Lines).
struct LogEntry: Codable {
    var t: Date
    var kind: String          // start, ocr, skip(note 첫 단어=이유), same(구버전), beat, pressure, error, stop
    var memMB: Double?        // 현재 phys_footprint
    var peakMB: Double?       // 최고 phys_footprint
    var availMB: Double?      // 한도까지 남은 메모리 (os_proc_available_memory)
    var ocrMs: Int?
    var battery: Float?       // 0~1
    var thermal: Int?         // 0 정상 ~ 3 위험
    var chars: Int?
    var text: String?
    var note: String?
}

/// 파일 끝에 한 줄씩 덧붙이는 기록기. 직렬 큐에서만 접근.
final class LogWriter {
    private let queue = DispatchQueue(label: "log.writer")
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    let url: URL

    init(url: URL = Shared.logURL) { self.url = url }

    func write(_ entry: LogEntry) {
        queue.async { [encoder, url] in
            autoreleasepool {
                guard var line = try? encoder.encode(entry) else { return }
                line.append(0x0A)
                if let h = try? FileHandle(forWritingTo: url) {
                    defer { try? h.close() }
                    _ = try? h.seekToEnd()
                    try? h.write(contentsOf: line)
                } else {
                    try? line.write(to: url, options: .atomic)
                }
            }
        }
    }

    func flush() { queue.sync {} }
}
