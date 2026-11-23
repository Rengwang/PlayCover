// Reuses the Sidecar placement approach from the local semantic-contract runner.
// Only launch/operate on apps explicitly selected for a benchmark; reject an existing session.
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

func wait(_ seconds: Double, until condition: () -> Bool) {
    let end = ProcessInfo.processInfo.systemUptime + seconds
    while !condition() && ProcessInfo.processInfo.systemUptime < end {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
}
func pause(_ seconds: Double) { wait(seconds) { false } }
func output(_ value: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data)
    print("")
}
func fail(_ reason: String) -> Never { output(["error": reason]); exit(1) }
func rect(_ r: CGRect) -> [String: Double] {
    ["x": r.minX, "y": r.minY, "width": r.width, "height": r.height]
}
func attribute(_ item: AXUIElement, _ name: CFString) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(item, name, &value) == .success else { return nil }
    return value
}
func windows(_ pid: pid_t) -> [(AXUIElement, CGRect)] {
    let app = AXUIElementCreateApplication(pid)
    let items = attribute(app, kAXWindowsAttribute as CFString) as? [AXUIElement] ?? []
    return items.compactMap { win in
        guard let p = attribute(win, kAXPositionAttribute as CFString),
              let s = attribute(win, kAXSizeAttribute as CFString),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point),
              AXValueGetValue(s as! AXValue, .cgSize, &size), size.width > 100, size.height > 100 else { return nil }
        return (win, CGRect(origin: point, size: size))
    }
}
func windowServerFrames(_ pid: pid_t) -> [CGRect] {
    let entries = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
    return entries.compactMap { entry in
        guard entry[kCGWindowOwnerPID as String] as? Int32 == pid,
              entry[kCGWindowLayer as String] as? Int == 0,
              let bounds = entry[kCGWindowBounds as String] as? [String: Any],
              let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
              frame.width > 100, frame.height > 100 else {
            return nil
        }
        return frame
    }
}
func frames(_ pid: pid_t) -> [CGRect] {
    let accessible = windows(pid).map { $0.1 }
    return accessible.isEmpty ? windowServerFrames(pid) : accessible
}
guard let primary = NSScreen.screens.first else { fail("No display") }
let target = NSScreen.screens.first { $0.localizedName.localizedCaseInsensitiveContains("Sidecar") } ?? primary
func quartz(_ frame: CGRect) -> CGRect {
    CGRect(x: frame.minX, y: primary.frame.height - frame.maxY, width: frame.width, height: frame.height)
}
let targetFrame = quartz(target.visibleFrame)
func place(_ pid: pid_t, requested: CGSize? = nil) -> [[String: Any]] {
    guard AXIsProcessTrusted() else { fail("Accessibility permission unavailable") }
    for (win, frame) in windows(pid) {
        var size = requested ?? frame.size
        size.width = min(size.width, targetFrame.width)
        size.height = min(size.height, targetFrame.height)
        var point = CGPoint(x: targetFrame.minX + max(0, (targetFrame.width - size.width) / 2),
                            y: targetFrame.minY + max(0, (targetFrame.height - size.height) / 2))
        // Move first so AppKit does not constrain the requested size on the old display.
        AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &point)!)
        AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &size)!)
    }
    pause(0.15)
    return frames(pid).map { frame in
        ["frame": rect(frame), "onTargetScreen": targetFrame.insetBy(dx: -2, dy: -2).contains(frame)]
    }
}
func summary(_ app: NSRunningApplication) -> [String: Any] {
    ["pid": app.processIdentifier, "bundleID": app.bundleIdentifier ?? "", "active": app.isActive,
     "hidden": app.isHidden, "terminated": app.isTerminated, "path": app.bundleURL?.path ?? "",
     "executable": app.executableURL?.path ?? "", "targetScreen": target.localizedName,
     "windowSource": windows(app.processIdentifier).isEmpty ? "windowServer" : "accessibility",
     "windows": frames(app.processIdentifier).map { frame in
         ["frame": rect(frame), "onTargetScreen": targetFrame.insetBy(dx: -2, dy: -2).contains(frame)]
     }]
}
let args = CommandLine.arguments
guard args.count >= 2 else { fail("Usage: window-runner screens|running|launch <path>|state <pid> <active|inactive|hidden|minimized|restore>|resize <pid> <w> <h>|quit <pid>") }
switch args[1] {
case "screens":
    output(["screens": NSScreen.screens.map { ["name": $0.localizedName, "frame": rect(quartz($0.frame))] },
            "targetScreen": target.localizedName, "targetFrame": rect(targetFrame)])
case "running":
    output(["apps": NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map(summary)])
case "launch":
    guard args.count == 3 else { fail("launch requires one app path") }
    let url = URL(fileURLWithPath: (args[2] as NSString).expandingTildeInPath).standardizedFileURL
    let bundle = Bundle(url: url) ?? Bundle(url: url.appendingPathComponent("WrappedBundle"))
    guard let identifier = bundle?.bundleIdentifier else { fail("No bundle identifier: \(url.path)") }
    guard NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty else {
        fail("Refusing to reuse an existing user session for \(identifier)")
    }
    guard AXIsProcessTrusted() else { fail("Accessibility permission unavailable") }
    let config = NSWorkspace.OpenConfiguration()
    config.activates = true
    config.addsToRecentItems = false
    config.environment = ["PLAYCOVER_TARGET_SCREEN": target == primary ? "primary" : "sidecar",
                          "PLAYTOOLS_AUTOMATION": "0", "PLAYTOOLS_SELFTEST": "0"]
    var app: NSRunningApplication?, error: Error?
    let start = ProcessInfo.processInfo.systemUptime
    var completionTime: Double?
    NSWorkspace.shared.openApplication(at: url, configuration: config) { opened, failure in
        app = opened; error = failure
        completionTime = ProcessInfo.processInfo.systemUptime - start
    }
    wait(25) { app != nil || error != nil }
    if let error { fail(error.localizedDescription) }
    guard let app else { fail("Launch timed out") }
    // Some Catalyst/Flutter apps lazily expose their native window only after an
    // accessibility client announces itself. Apply the same probe to both variants.
    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    wait(25) { app.isTerminated || !frames(app.processIdentifier).isEmpty }
    let firstWindow = ProcessInfo.processInfo.systemUptime - start
    let firstWindowWasAccessible = !windows(app.processIdentifier).isEmpty
    guard !app.isTerminated, !frames(app.processIdentifier).isEmpty else {
        let pid = app.processIdentifier
        if !app.isTerminated { app.terminate(); wait(45) { app.isTerminated } }
        fail("App exited or no accessible window (pid \(pid), terminated=\(app.isTerminated))")
    }
    _ = place(app.processIdentifier)
    // Some apps create a second startup window or restore their saved frame after launch.
    pause(0.5)
    _ = place(app.processIdentifier)
    var value = summary(app)
    value["openCompletionSeconds"] = completionTime
    value["firstWindowSeconds"] = firstWindow
    value["firstAXWindowSeconds"] = firstWindowWasAccessible ? firstWindow as Any : NSNull()
    value["includesHostPreparation"] = false
    output(value)
case "state", "resize", "quit", "inspect":
    guard args.count >= 3, let pid = Int32(args[2]), let app = NSRunningApplication(processIdentifier: pid) else {
        fail("Missing running PID")
    }
    if args[1] == "inspect" {
        output(summary(app))
    } else if args[1] == "quit" {
        let accepted = app.terminate()
        // UIKit can grant a 35-second background-task grace period during a normal quit.
        wait(45) { app.isTerminated }
        output(["pid": pid, "quitAccepted": accepted, "terminated": app.isTerminated])
    } else if args[1] == "resize" {
        guard args.count == 5, let w = Double(args[3]), let h = Double(args[4]), w > 100, h > 100 else {
            fail("resize requires width and height > 100")
        }
        _ = place(pid, requested: CGSize(width: w, height: h))
        guard frames(pid).contains(where: { abs($0.width - w) <= 2 && abs($0.height - h) <= 2 }) else {
            fail("Requested geometry unavailable; do not compare this sample as an equal-size window")
        }
        output(summary(app))
    } else {
        guard args.count == 4 else { fail("state requires a mode") }
        switch args[3] {
        case "active", "restore":
            for (win, _) in windows(pid) { AXUIElementSetAttributeValue(win, kAXMinimizedAttribute as CFString, kCFBooleanFalse) }
            app.unhide(); app.activate(options: [.activateAllWindows])
            pause(0.15); _ = place(pid)
        case "inactive":
            // The benchmark helper takes focus without opening a window or moving another app.
            NSApplication.shared.setActivationPolicy(.accessory)
            NSApplication.shared.activate(ignoringOtherApps: true)
            wait(2) { !app.isActive }
        case "hidden": app.hide(); wait(2) { app.isHidden }
        case "minimized":
            for (win, _) in windows(pid) { AXUIElementSetAttributeValue(win, kAXMinimizedAttribute as CFString, kCFBooleanTrue) }
        default: fail("Unknown state mode")
        }
        output(summary(app))
    }
default: fail("Unknown command")
}
