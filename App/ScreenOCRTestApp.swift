import SwiftUI
import ReplayKit

@main
struct ScreenOCRTestApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

/// 앱 안에 들어 있는 방송 확장의 번들 ID를 실제로 찾아낸다.
/// (사이드로딩 도구가 번들 ID를 바꿔도 동작하도록)
enum ExtensionInfo {
    static let bundleID: String? = {
        guard let dir = Bundle.main.builtInPlugInsURL,
              let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return nil }
        return items.first(where: { $0.pathExtension == "appex" })
            .flatMap { Bundle(url: $0)?.bundleIdentifier }
    }()
}

/// 시스템 "화면 방송 시작" 버튼.
struct BroadcastPickerButton: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let v = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 60, height: 60))
        v.preferredExtension = ExtensionInfo.bundleID
        v.showsMicrophoneButton = false
        return v
    }
    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}
