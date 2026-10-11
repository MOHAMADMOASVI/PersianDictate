import AppKit

let arguments = CommandLine.arguments
if let flag = arguments.firstIndex(of: "--simulate"), arguments.count > flag + 1 {
    Simulation.run(path: arguments[flag + 1],
                   language: arguments.count > flag + 2 ? arguments[flag + 2] : nil,
                   translation: arguments.count > flag + 3 ? arguments[flag + 3] : nil)
}
if let flag = arguments.firstIndex(of: "--snapshot"), arguments.count > flag + 1 {
    _ = NSApplication.shared
    DashboardSnapshot.write(to: arguments[flag + 1])
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
