import AppKit

if CommandLine.arguments.contains("--self-test") {
    do { try SelfTest.run() } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
} else {
    let app = NSApplication.shared
    let controller = AppController()
    app.delegate = controller
    withExtendedLifetime(controller) { app.run() }
}
