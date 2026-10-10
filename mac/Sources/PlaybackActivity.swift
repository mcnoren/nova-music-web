import Foundation

/// Keep user-requested audio responsive when the window is covered or minimized.
/// Release immediately on pause, ownership change, navigation, or termination.
@MainActor
final class PlaybackActivity {
    private var token: NSObjectProtocol?
    private let begin: () -> NSObjectProtocol
    private let end: (NSObjectProtocol) -> Void
    init(begin: @escaping () -> NSObjectProtocol = {
        ProcessInfo.processInfo.beginActivity(options:.userInitiatedAllowingIdleSystemSleep,reason:"Playing music")
    }, end: @escaping (NSObjectProtocol) -> Void = { ProcessInfo.processInfo.endActivity($0) }) {
        self.begin = begin; self.end = end
    }
    func setPlaying(_ playing: Bool) {
        if playing, token == nil { token = begin() }
        else if !playing, let active = token { token = nil; end(active) }
    }
}
