import Foundation

@main struct PlaybackActivityTests {
    @MainActor static func main() {
        var begins = 0, ends = 0
        let token = NSObject()
        let activity = PlaybackActivity(begin:{ begins += 1; return token },end:{ value in
            precondition(value === token); ends += 1
        })
        activity.setPlaying(false); precondition(begins == 0 && ends == 0)
        activity.setPlaying(true)
        for _ in 0..<50 { activity.setPlaying(true) }
        precondition(begins == 1 && ends == 0,"Heartbeats must retain one activity")
        activity.setPlaying(false); activity.setPlaying(false)
        precondition(begins == 1 && ends == 1,"Pause or remote ownership must release once")
        activity.setPlaying(true);activity.setPlaying(false)
        precondition(begins == 2 && ends == 2,"Resume and termination must balance")
        print("Playback activity lifecycle passed")
    }
}
