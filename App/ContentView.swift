import SwiftUI

struct ContentView: View {
    @StateObject private var store = LogStore()
    @State private var settings = OCRSettings.load()
    @State private var confirmClear = false
    private let timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 16) {
                        BroadcastPickerButton()
                            .frame(width: 60, height: 60)
                        Text("왼쪽 버튼 → \"방송 시작\". 끝낼 땐 화면 위 빨간 표시나 제어 센터에서 중단하세요.")
                            .font(.footnote)
                    }
                } header: { Text("1. 화면 방송") }

                Section {
                    Stepper("간격: \(Int(settings.interval))초", value: $settings.interval, in: 2...30, step: 1)
                    Picker("축소 비율", selection: $settings.scale) {
                        ForEach([0.4, 0.5, 0.6, 0.75, 1.0], id: \.self) { v in
                            Text(v >= 1 ? "원본" : "\(Int(v * 100))%").tag(v)
                        }
                    }
                    Toggle("언어 보정 (느려짐)", isOn: $settings.languageCorrection)
                } header: { Text("2. 설정") } footer: {
                    Text("설정은 방송을 다시 시작해야 적용됩니다.")
                }
                .onChange(of: settings.interval) { _ in settings.save() }
                .onChange(of: settings.scale) { _ in settings.save() }
                .onChange(of: settings.languageCorrection) { _ in settings.save() }

                Section { summaryView } header: { Text("3. 마지막 방송 요약") }

                Section {
                    ForEach(store.entries.suffix(300).reversed()) { item in
                        NavigationLink { EntryDetail(e: item.e) } label: { EntryRow(e: item.e) }
                    }
                } header: { Text("로그 (최근 300줄, 전체 \(store.entries.count)줄)") }

                Section { diagnostics } header: { Text("진단") }
            }
            .navigationTitle("OCR 시험 v\(Shared.appVersion.split(separator: " ").first.map(String.init) ?? "")")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    ShareLink(item: store.fileURL) { Image(systemName: "square.and.arrow.up") }
                    Button(role: .destructive) { confirmClear = true } label: { Image(systemName: "trash") }
                }
            }
            .confirmationDialog("로그를 모두 지울까요?", isPresented: $confirmClear) {
                Button("지우기", role: .destructive) { store.clear() }
            }
            .onAppear { store.reload() }
            .onReceive(timer) { _ in store.reload() }
        }
    }

    @ViewBuilder private var summaryView: some View {
        let s = store.summary
        if s.start == nil {
            Text("아직 기록이 없습니다.").foregroundStyle(.secondary)
        } else {
            LabeledContent("시간", value: String(format: "%.1f분", s.minutes))
            LabeledContent("OCR 실행 / 기록 / 건너뜀", value: "\(s.ocrRuns) / \(s.changed) / \(s.skippedTotal)")
            LabeledContent("건너뜀: 이 앱 / 홈 / 빈 화면",
                           value: ["self", "home", "empty"].map { "\(s.skipped[$0] ?? 0)" }.joined(separator: " / "))
            LabeledContent("OCR 평균 / 최대", value: "\(s.avgOcrMs) / \(s.maxOcrMs) ms")
            LabeledContent("최대 메모리", value: String(format: "%.1f MB", s.peakMB))
            if let a = s.minAvailMB {
                LabeledContent("한도까지 최소 여유", value: String(format: "%.1f MB", a))
            }
            LabeledContent("메모리 경고 / 오류", value: "\(s.pressure) / \(s.errors)")
            if let b = s.batteryPerHour {
                LabeledContent("배터리 소모", value: String(format: "%.1f%%/시간", b))
            } else {
                LabeledContent("배터리 소모", value: "10분 이상 필요")
            }
            LabeledContent("최고 발열 단계", value: ["정상", "약간", "높음", "위험"][min(s.maxThermal, 3)])
            LabeledContent("종료 기록", value: s.stopped ? "정상 종료" : "없음 (진행 중이거나 강제 종료)")
        }
    }

    @ViewBuilder private var diagnostics: some View {
        LabeledContent("버전", value: Shared.appVersion)
        LabeledContent("App Group", value: Shared.appGroupID)
        LabeledContent("공유 폴더 접근", value: Shared.isGroupAvailable ? "성공" : "실패")
        LabeledContent("서명된 그룹", value: Shared.provisionedGroups.isEmpty ? "(없음)" : Shared.provisionedGroups.joined(separator: ", "))
        LabeledContent("방송 확장 ID", value: ExtensionInfo.bundleID ?? "(못 찾음)")
    }
}

struct EntryRow: View {
    let e: LogEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(e.t, format: .dateTime.hour().minute().second())
                Text(e.kind).bold()
                Spacer()
                if let m = e.memMB { Text(String(format: "%.1fMB", m)) }
                if let ms = e.ocrMs { Text("\(ms)ms") }
            }
            .font(.caption.monospacedDigit())
            if let t = e.text, !t.isEmpty {
                Text(t).font(.caption2).lineLimit(2).foregroundStyle(.secondary)
            } else if let n = e.note {
                Text(n).font(.caption2).lineLimit(2).foregroundStyle(.secondary)
            }
        }
    }
}

struct EntryDetail: View {
    let e: LogEntry
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(e.t.formatted()) · \(e.kind)").bold()
                Text("메모리 \(e.memMB ?? 0, specifier: "%.1f")MB · 최대 \(e.peakMB ?? 0, specifier: "%.1f")MB · 여유 \(e.availMB ?? 0, specifier: "%.1f")MB")
                if let ms = e.ocrMs { Text("OCR \(ms)ms · \(e.chars ?? 0)자") }
                if let n = e.note { Text(n).foregroundStyle(.secondary) }
                Divider()
                Text(e.text ?? "").textSelection(.enabled)
            }
            .font(.callout)
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
