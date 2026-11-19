import Foundation

struct IndexedEntry: Identifiable {
    let id: Int
    let e: LogEntry
}

/// 마지막 방송 세션 요약.
struct SessionSummary {
    var start: Date?
    var end: Date?
    var ocrRuns = 0
    var changed = 0
    /// 건너뛴 이유별 개수 (self, home, empty)
    var skipped: [String: Int] = [:]
    var skippedTotal: Int { skipped.values.reduce(0, +) }
    var errors = 0
    var pressure = 0
    var avgOcrMs = 0
    var maxOcrMs = 0
    var peakMB = 0.0
    var minAvailMB: Double?
    var batteryStart: Float?
    var batteryEnd: Float?
    var maxThermal = 0
    var stopped = false

    var minutes: Double {
        guard let s = start, let e = end else { return 0 }
        return e.timeIntervalSince(s) / 60
    }
    /// 시간당 배터리 소모 (%p). 30분 이상 돌려야 의미 있음.
    var batteryPerHour: Double? {
        guard let a = batteryStart, let b = batteryEnd, minutes >= 10 else { return nil }
        return Double(a - b) * 100 / (minutes / 60)
    }
}

@MainActor
final class LogStore: ObservableObject {
    @Published var entries: [IndexedEntry] = []
    @Published var summary = SessionSummary()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    var fileURL: URL { Shared.logURL }

    func reload() {
        guard let data = try? Data(contentsOf: fileURL) else {
            entries = []; summary = SessionSummary(); return
        }
        var list: [IndexedEntry] = []
        var i = 0
        for line in data.split(separator: 0x0A) {
            if let e = try? decoder.decode(LogEntry.self, from: Data(line)) {
                list.append(IndexedEntry(id: i, e: e)); i += 1
            }
        }
        entries = list
        summary = summarize(list.map(\.e))
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
        reload()
    }

    private func summarize(_ all: [LogEntry]) -> SessionSummary {
        let startIdx = all.lastIndex(where: { $0.kind == "start" }) ?? 0
        let session = all[startIdx...]
        var s = SessionSummary()
        s.start = session.first?.t
        s.end = session.last?.t
        var totalMs = 0
        for e in session {
            if let m = e.peakMB ?? e.memMB { s.peakMB = max(s.peakMB, m) }
            if let a = e.availMB { s.minAvailMB = min(s.minAvailMB ?? a, a) }
            if let b = e.battery {
                if s.batteryStart == nil { s.batteryStart = b }
                s.batteryEnd = b
            }
            s.maxThermal = max(s.maxThermal, e.thermal ?? 0)
            switch e.kind {
            case "ocr", "same", "skip":
                s.ocrRuns += 1
                if e.kind == "ocr" { s.changed += 1 }
                if e.kind == "skip" {
                    let reason = e.note?.split(separator: " ").first.map(String.init) ?? "?"
                    s.skipped[reason, default: 0] += 1
                }
                if let ms = e.ocrMs { totalMs += ms; s.maxOcrMs = max(s.maxOcrMs, ms) }
            case "error": s.errors += 1
            case "pressure": s.pressure += 1
            case "stop": s.stopped = true
            default: break
            }
        }
        s.avgOcrMs = s.ocrRuns > 0 ? totalMs / s.ocrRuns : 0
        return s
    }
}
