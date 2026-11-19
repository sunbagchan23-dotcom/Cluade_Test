import ReplayKit
import Vision
import Accelerate
import UIKit

/// 화면 방송 확장. 메모리 한도(실측 약 300MB, 원래 가정은 50MB) 안에서 N초마다 한 프레임만 OCR한다.
///
/// 메모리 절약 방식
/// - 처리 중이거나 간격이 안 됐으면 프레임을 즉시 버린다 (큐에 쌓지 않음).
/// - 컬러(YUV) 프레임에서 밝기(Y) 평면만 꺼내 축소한다. OCR엔 흑백이면 충분하고,
///   GPU(CoreImage/Metal)를 쓰지 않아 그쪽 메모리도 안 든다.
/// - 축소용 버퍼는 한 번 만들어 계속 재사용한다.
/// - 원본 프레임은 축소 직후 놓아준다 (ReplayKit 버퍼 풀을 붙잡지 않음).
/// - 매 OCR을 autoreleasepool로 감싸 임시 객체를 바로 해제한다.
final class SampleHandler: RPBroadcastSampleHandler {
    private let ocrQueue = DispatchQueue(label: "ocr", qos: .utility)
    private let lock = NSLock()
    private var busy = false
    private var lastFrameTime: CFTimeInterval = 0

    private var settings = OCRSettings.load()
    private let log = LogWriter()
    /// 직전에 기록한 글자. 완전히 같을 때만 "same"으로 글자 없이 남긴다 (필터 이전과 같은 동작).
    private var lastText = ""
    /// 직전 기록(비교용 정규화 문자열). 유사도는 기록만 하고 건너뛰는 데 쓰지 않는다.
    private var lastNorm = ""
    /// 건너뛴 이유별 개수: self(이 앱), home(홈 화면), empty(글자 거의 없음)
    private var skipped: [String: Int] = [:]
    private var removedStatusLines = 0
    private var removedKeyboardLines = 0
    private var grayBuffer: CVPixelBuffer?
    private var memSource: DispatchSourceMemoryPressure?
    private var beat: DispatchSourceTimer?
    private var ocrCount = 0

    // MARK: - 방송 수명주기

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        settings = OCRSettings.load()
        UIDevice.current.isBatteryMonitoringEnabled = true
        let note = "interval=\(settings.interval)s scale=\(settings.scale) lc=\(settings.languageCorrection) " +
            "group=\(Shared.appGroupID) shared=\(Shared.isGroupAvailable) provisioned=\(Shared.provisionedGroups)"
        write("start", note: note)

        let src = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: ocrQueue)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let ev = src.data.contains(.critical) ? "critical" : "warning"
            self.write("pressure", note: ev)
        }
        src.resume()
        memSource = src

        // 화면이 안 바뀌면 프레임이 안 오므로, 1분마다 메모리·배터리를 따로 기록한다.
        let t = DispatchSource.makeTimerSource(queue: ocrQueue)
        t.schedule(deadline: .now() + 60, repeating: 60)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.write("beat", note: self.statsNote())
        }
        t.resume()
        beat = t
    }

    override func broadcastPaused() { write("pause") }
    override func broadcastResumed() { write("resume") }

    override func broadcastFinished() {
        beat?.cancel(); memSource?.cancel()
        // 집계 값은 ocr 큐에서만 바뀌므로 같은 큐에서 읽는다.
        ocrQueue.sync { write("stop", note: "ocrCount=\(ocrCount) " + statsNote()) }
        log.flush()
    }

    // MARK: - 프레임 처리

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video else { return }

        let now = CACurrentMediaTime()
        lock.lock()
        if busy || now - lastFrameTime < settings.interval {
            lock.unlock()
            return
        }
        busy = true
        lastFrameTime = now
        lock.unlock()

        guard let pixel = CMSampleBufferGetImageBuffer(sampleBuffer) else { finish(); return }

        var orientation = CGImagePropertyOrientation.up
        if let n = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString,
                                   attachmentModeOut: nil) as? NSNumber,
           let o = CGImagePropertyOrientation(rawValue: n.uint32Value) {
            orientation = o
        }

        // 축소본을 만들 수 있으면 그것만 넘기고 원본은 이 함수가 끝나면 놓아준다.
        var input: CVPixelBuffer = pixel
        var note: String?
        if settings.scale < 0.99 {
            if let small = makeGrayDownscaled(pixel) {
                input = small
            } else {
                note = "downscale-skip fmt=\(CVPixelBufferGetPixelFormatType(pixel))"
            }
        }
        ocrQueue.async { [weak self] in
            self?.recognize(input, orientation: orientation, note: note)
        }
    }

    private func finish() {
        lock.lock(); busy = false; lock.unlock()
    }

    /// YUV 420 프레임의 Y(밝기) 평면만 축소해 흑백 버퍼로 만든다.
    private func makeGrayDownscaled(_ src: CVPixelBuffer) -> CVPixelBuffer? {
        let fmt = CVPixelBufferGetPixelFormatType(src)
        guard fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
              fmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else { return nil }

        let w = CVPixelBufferGetWidthOfPlane(src, 0)
        let h = CVPixelBufferGetHeightOfPlane(src, 0)
        let dw = max(64, Int(Double(w) * settings.scale))
        let dh = max(64, Int(Double(h) * settings.scale))

        if let g = grayBuffer, CVPixelBufferGetWidth(g) != dw || CVPixelBufferGetHeight(g) != dh {
            grayBuffer = nil // 화면 회전 등으로 크기가 바뀜
        }
        if grayBuffer == nil {
            var out: CVPixelBuffer?
            let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
            CVPixelBufferCreate(nil, dw, dh, kCVPixelFormatType_OneComponent8, attrs, &out)
            grayBuffer = out
        }
        guard let dst = grayBuffer else { return nil }

        CVPixelBufferLockBaseAddress(src, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(dst, [])
            CVPixelBufferUnlockBaseAddress(src, .readOnly)
        }
        guard let sBase = CVPixelBufferGetBaseAddressOfPlane(src, 0),
              let dBase = CVPixelBufferGetBaseAddress(dst) else { return nil }

        var s = vImage_Buffer(data: sBase, height: vImagePixelCount(h), width: vImagePixelCount(w),
                              rowBytes: CVPixelBufferGetBytesPerRowOfPlane(src, 0))
        var d = vImage_Buffer(data: dBase, height: vImagePixelCount(dh), width: vImagePixelCount(dw),
                              rowBytes: CVPixelBufferGetBytesPerRow(dst))
        let err = vImageScale_Planar8(&s, &d, nil, vImage_Flags(kvImageNoFlags))
        return err == kvImageNoError ? dst : nil
    }

    private func recognize(_ pixel: CVPixelBuffer, orientation: CGImagePropertyOrientation, note: String?) {
        defer { finish() }
        let t0 = CACurrentMediaTime()
        var lines: [OCRLine] = []
        var errorNote: String?

        autoreleasepool {
            let req = VNRecognizeTextRequest()
            req.revision = VNRecognizeTextRequestRevision3 // 한국어 지원 (iOS 16+)
            req.recognitionLevel = .accurate                // 한국어는 accurate에서만 지원
            req.recognitionLanguages = ["ko-KR", "en-US"]
            req.usesLanguageCorrection = settings.languageCorrection
            let handler = VNImageRequestHandler(cvPixelBuffer: pixel, orientation: orientation, options: [:])
            do {
                try handler.perform([req])
                lines = (req.results ?? []).compactMap { obs in
                    guard let s = obs.topCandidates(1).first?.string else { return nil }
                    return OCRLine(text: s, midY: Double(obs.boundingBox.midY))
                }
            } catch {
                errorNote = error.localizedDescription
            }
        }

        let ms = Int((CACurrentMediaTime() - t0) * 1000)
        ocrCount += 1
        if let errorNote {
            write("error", ocrMs: ms, note: errorNote)
            return
        }
        let size = "\(CVPixelBufferGetWidth(pixel))x\(CVPixelBufferGetHeight(pixel))"
        let fullNote = [note, size].compactMap { $0 }.joined(separator: " ")

        // 1) 상태바·키보드 줄 빼기
        let sb = ScreenFilter.dropStatusBar(lines)
        let kb = ScreenFilter.dropKeyboard(sb.kept)
        removedStatusLines += sb.removed
        removedKeyboardLines += kb.removed
        let kept = kb.kept
        let text = kept.map(\.text).joined(separator: "\n")
        let cutNote = "\(fullNote) sb=\(sb.removed) kb=\(kb.removed)"

        // 2) 이 앱·홈 화면은 기록 안 함
        if let reason = ScreenFilter.skipReason(kept) {
            skip(reason, ms: ms, text: text, note: cutNote)
            return
        }
        // 3) 글자가 거의 없으면 기록 안 함
        //    (90% 유사 중복 건너뛰기는 2026-11-19 실기기 시험에서 새 카톡 메시지가 있는 화면을
        //     sim=0.91로 버려서 되돌렸다. 유사도 값은 note에 기록만 한다.)
        let norm = ScreenFilter.normalize(text)
        if norm.count < 10 {
            skip("empty", ms: ms, text: text, note: cutNote)
            return
        }
        let simNote = cutNote + String(format: " sim=%.2f", ScreenFilter.similarity(norm, lastNorm))
        if text == lastText {
            write("same", ocrMs: ms, chars: text.count, note: simNote)
            return
        }
        lastText = text
        lastNorm = norm
        write("ocr", ocrMs: ms, chars: text.count, text: text, note: simNote)
    }

    /// 건너뛴 화면도 시험 중에는 글자를 남긴다. 잘못 걸러진 게 있는지 사람이 확인하기 위해서다.
    /// (나중에 AI로 보낼 때는 kind == "ocr"만 보낸다.)
    private func skip(_ reason: String, ms: Int, text: String, note: String) {
        skipped[reason, default: 0] += 1
        write("skip", ocrMs: ms, chars: text.count, text: text, note: "\(reason) \(note)")
    }

    private func statsNote() -> String {
        let s = ["self", "home", "empty"].map { "\($0)=\(skipped[$0] ?? 0)" }.joined(separator: " ")
        return "skip[\(s)] removedLines[sb=\(removedStatusLines) kb=\(removedKeyboardLines)]"
    }

    // MARK: - 기록

    private func write(_ kind: String, ocrMs: Int? = nil, chars: Int? = nil, text: String? = nil, note: String? = nil) {
        let m = MemoryInfo.snapshot()
        let level = UIDevice.current.batteryLevel
        log.write(LogEntry(
            t: Date(), kind: kind,
            memMB: m.footprintMB, peakMB: m.peakMB, availMB: m.availableMB,
            ocrMs: ocrMs,
            battery: level >= 0 ? level : nil,
            thermal: ProcessInfo.processInfo.thermalState.rawValue,
            chars: chars, text: text, note: note
        ))
    }
}
