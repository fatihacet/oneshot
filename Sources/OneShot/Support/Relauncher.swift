import AppKit

enum Relauncher {
    /// Quits and reopens OneShot, e.g. after granting Screen Recording permission.
    @MainActor
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 0.7; /usr/bin/open \"\(path)\""]
        try? process.run()
        NSApp.terminate(nil)
    }
}
