import Foundation

/// OCR 한 줄. midY는 Vision 좌표(아래 0, 위 1) 기준 글자 상자의 세로 중심.
struct OCRLine {
    let text: String
    let midY: Double
}

/// OCR 결과에서 잡음(상태바·키보드)을 빼고, 기록할 가치가 없는 화면(이 앱, 홈 화면)과
/// 중복 화면을 가려내는 규칙. 위치 정보가 로그에 없어서 위치 기준값은 화면 비율로 추정한 값이다.
enum ScreenFilter {

    // MARK: 1. 상태바

    /// 상태바(시계·배터리)는 화면 위 약 4% 안에 있다 (1290x2796 스크린샷 실측: 시계 중심 3.2%).
    /// 앱 제목줄 글자 중심은 약 8%라서 5.5%를 경계로 잡는다.
    static let statusBarMidY = 0.945

    static func dropStatusBar(_ lines: [OCRLine]) -> (kept: [OCRLine], removed: Int) {
        let kept = lines.filter { $0.midY <= statusBarMidY }
        return (kept, lines.count - kept.count)
    }

    // MARK: 2. 키보드

    private static let qwertyRows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]

    private static func isJamo(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value, c.unicodeScalars.count == 1 else { return false }
        return (0x3131...0x318E).contains(v) // 한글 호환 자모 (ㄱ~ㅣ, ㆍ)
    }

    /// 키보드 글쇠처럼 보이는 줄의 가중치. 0이면 글쇠 아님, 3이면 한 줄이 통째로 글쇠 줄.
    private static func keyWeight(_ text: String) -> Int {
        let s = text.filter { !$0.isWhitespace }
        guard !s.isEmpty else { return 0 }
        if s.allSatisfy(isJamo) { return s.count >= 4 ? 3 : 1 }
        let lower = s.lowercased()
        if s.count >= 4, qwertyRows.contains(where: { $0.contains(lower) }) { return 3 }
        if s.count <= 2, s.allSatisfy({ $0.isASCII && $0.isLetter }) { return 1 }
        return 0
    }

    /// 화면 아래쪽 절반에 글쇠 같은 짧은 글자가 같은 높이로 여러 개 모여 있으면 키보드로 본다.
    /// 키보드 맨 윗줄보다 조금 위(추천 단어 줄)까지 모두 뺀다. 입력창은 그 위라 남는다.
    static func dropKeyboard(_ lines: [OCRLine]) -> (kept: [OCRLine], removed: Int) {
        let keys = lines.compactMap { l -> (Double, Int)? in
            guard l.midY < 0.5 else { return nil }
            let w = keyWeight(l.text)
            return w > 0 ? (l.midY, w) : nil
        }
        // 같은 높이(±2%)에 글쇠 가중치 합이 3 이상이면 글쇠 줄
        let rowTops = keys.filter { k in
            keys.filter { abs($0.0 - k.0) < 0.02 }.reduce(0) { $0 + $1.1 } >= 3
        }.map { $0.0 }
        // 글쇠 줄이 2줄 이상(서로 4% 이상 떨어짐)일 때만 키보드로 인정
        guard let top = rowTops.max(), let bottom = rowTops.min(), top - bottom > 0.04 else {
            return (lines, 0)
        }
        let cut = top + 0.07
        let kept = lines.filter { $0.midY >= cut }
        return (kept, lines.count - kept.count)
    }

    // MARK: 3. 기록하지 않을 화면

    private static func squeeze(_ s: String) -> String { s.filter { !$0.isWhitespace } }

    /// 이 시험 앱 화면과 방송 시작/중단 창에만 나오는 문구 (띄어쓰기 무시).
    private static let selfMarkers = ["OCR시험", "한도까지최소여유", "마지막방송요약", "축소비율", "언어보정", "내용바뀜", "OCR시험방송",
                                      "방송중단", "공유폴더접근", "서명된그룹", "방송확장ID", "방해금지"]

    /// 홈 화면에 흔한 기본 앱 이름.
    private static let stockApps: Set<String> = [
        "설정", "사진", "카메라", "AppStore", "시계", "날씨", "지도", "메모", "미리알림", "캘린더", "메일",
        "전화", "메시지", "Safari", "음악", "파일", "건강", "지갑", "단축어", "계산기", "나의찾기",
        "FaceTime", "팟캐스트", "주식", "번역", "홈", "음성메모", "TV", "도서", "Watch"]

    /// "self"(이 앱), "home"(홈 화면) 또는 nil(기록 대상).
    static func skipReason(_ lines: [OCRLine]) -> String? {
        let joined = squeeze(lines.map(\.text).joined())
        if selfMarkers.filter({ joined.contains($0) }).count >= 2 { return "self" }

        // 홈 화면: 줄이 많고 전부 짧음(앱 이름) + 기본 앱 이름 3개 이상 또는 아래쪽 "검색" 버튼
        guard lines.count >= 8 else { return nil }
        let squeezed = lines.map { squeeze($0.text) }
        let lens = squeezed.map(\.count)
        let shortRatio = Double(lens.filter { $0 <= 12 }.count) / Double(lens.count)
        let stock = squeezed.filter { stockApps.contains($0) }.count
        let search = squeezed.contains { $0.hasSuffix("검색") && $0.count <= 4 }
        if (lens.max() ?? 0) <= 20, shortRatio >= 0.85, stock >= 3 || search { return "home" }
        return nil
    }

    // MARK: 4. 중복

    private static let clockRegex = try! NSRegularExpression(pattern: "\\d{1,2}:\\d{2}(:\\d{2})?")

    /// 비교용 문자열: 시각(12:34) 제거, 공백 제거.
    static func normalize(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let noClock = clockRegex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        return squeeze(noClock)
    }

    /// 두 글자 묶음(bigram) 겹침 비율(Dice). 1이면 같음. 스크롤로 줄이 밀려도 크게 안 떨어진다.
    static func similarity(_ a: String, _ b: String) -> Double {
        func grams(_ s: String) -> [String: Int] {
            let c = Array(s)
            var d: [String: Int] = [:]
            if c.count >= 2 { for i in 0..<(c.count - 1) { d[String(c[i...i + 1]), default: 0] += 1 } }
            return d
        }
        let ga = grams(a), gb = grams(b)
        let total = ga.values.reduce(0, +) + gb.values.reduce(0, +)
        if total == 0 { return a == b ? 1 : 0 }
        let common = ga.reduce(0) { $0 + min($1.value, gb[$1.key] ?? 0) }
        return Double(2 * common) / Double(total)
    }
}
