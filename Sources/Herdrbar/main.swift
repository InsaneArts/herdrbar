import AppKit

// herdr refuses to start inside another herdr ("nested herdr is disabled"). Launch Services hands every
// app Herdrbar opens its environment, so a Herdrbar started from a herdr pane drops herdr's variables first.
for key in ProcessInfo.processInfo.environment.keys where key.hasPrefix("HERDR_") { unsetenv(key) }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
