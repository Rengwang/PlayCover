//
//  SettingsView.swift
//  PlayCover
//
//  Created by Andrew Glaze on 7/16/22.
//

import AppKit
import Sparkle
import SwiftUI

struct GlobalBackSettingsData: Codable, Equatable {
    var titlebarBackEnabled: Bool = true
    var onlyWhenNoSidebarBackButton: Bool = true
    var includeTopCloseButtons: Bool = true
    var shortcutEnabled: Bool = true
    var shortcutKind: String = "mouse"
    var shortcutKeyCode: UInt16 = 0
    var shortcutButtonNumber: Int = 3
    var shortcutModifiersRaw: UInt = 0
    var shortcutDisplayName: String = "Mouse Button 4"
    var titlebarHomeEnabled: Bool = true
    var homeShortcutEnabled: Bool = true
    var homeShortcutKind: String = "none"
    var homeShortcutKeyCode: UInt16 = 0
    var homeShortcutButtonNumber: Int = -1
    var homeShortcutModifiersRaw: UInt = 0
    var homeShortcutDisplayName: String = ""

    static var defaultSettings: GlobalBackSettingsData {
        GlobalBackSettingsData()
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GlobalBackSettingsData.defaultSettings
        titlebarBackEnabled = try c.decodeIfPresent(Bool.self, forKey: .titlebarBackEnabled) ?? d.titlebarBackEnabled
        onlyWhenNoSidebarBackButton = try c.decodeIfPresent(Bool.self, forKey: .onlyWhenNoSidebarBackButton) ?? d.onlyWhenNoSidebarBackButton
        includeTopCloseButtons = try c.decodeIfPresent(Bool.self, forKey: .includeTopCloseButtons) ?? d.includeTopCloseButtons
        shortcutEnabled = try c.decodeIfPresent(Bool.self, forKey: .shortcutEnabled) ?? d.shortcutEnabled
        shortcutKind = try c.decodeIfPresent(String.self, forKey: .shortcutKind) ?? d.shortcutKind
        shortcutKeyCode = try c.decodeIfPresent(UInt16.self, forKey: .shortcutKeyCode) ?? d.shortcutKeyCode
        shortcutButtonNumber = try c.decodeIfPresent(Int.self, forKey: .shortcutButtonNumber) ?? d.shortcutButtonNumber
        shortcutModifiersRaw = try c.decodeIfPresent(UInt.self, forKey: .shortcutModifiersRaw) ?? d.shortcutModifiersRaw
        shortcutDisplayName = try c.decodeIfPresent(String.self, forKey: .shortcutDisplayName) ?? d.shortcutDisplayName
        titlebarHomeEnabled = try c.decodeIfPresent(Bool.self, forKey: .titlebarHomeEnabled) ?? d.titlebarHomeEnabled
        homeShortcutEnabled = try c.decodeIfPresent(Bool.self, forKey: .homeShortcutEnabled) ?? d.homeShortcutEnabled
        homeShortcutKind = try c.decodeIfPresent(String.self, forKey: .homeShortcutKind) ?? d.homeShortcutKind
        homeShortcutKeyCode = try c.decodeIfPresent(UInt16.self, forKey: .homeShortcutKeyCode) ?? d.homeShortcutKeyCode
        homeShortcutButtonNumber = try c.decodeIfPresent(Int.self, forKey: .homeShortcutButtonNumber) ?? d.homeShortcutButtonNumber
        homeShortcutModifiersRaw = try c.decodeIfPresent(UInt.self, forKey: .homeShortcutModifiersRaw) ?? d.homeShortcutModifiersRaw
        homeShortcutDisplayName = try c.decodeIfPresent(String.self, forKey: .homeShortcutDisplayName) ?? d.homeShortcutDisplayName
    }
}

final class GlobalBackSettingsStore: ObservableObject {
    static let shared = GlobalBackSettingsStore()
    static let changedNotification = Notification.Name("io.playcover.PlayCover.GlobalBackSettingsChanged")
    static var plistURL: URL {
        PlayTools.playCoverContainer.appendingPathComponent("GlobalBackSettings.plist")
    }

    @Published var data: GlobalBackSettingsData {
        didSet {
            if !isLoading {
                save()
            }
        }
    }

    private var isLoading = false

    private init() {
        isLoading = true
        if let raw = try? Data(contentsOf: Self.plistURL),
           let decoded = try? PropertyListDecoder().decode(GlobalBackSettingsData.self, from: raw) {
            data = decoded
        } else {
            data = GlobalBackSettingsData.defaultSettings
        }
        isLoading = false
    }

    func save() {
        let dir = Self.plistURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        if let encoded = try? encoder.encode(data) {
            try? encoded.write(to: Self.plistURL, options: .atomic)
            DistributedNotificationCenter.default().postNotificationName(
                Self.changedNotification,
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
        }
    }

    func resetShortcutToDefault() {
        let d = GlobalBackSettingsData.defaultSettings
        data.shortcutKind = d.shortcutKind
        data.shortcutKeyCode = d.shortcutKeyCode
        data.shortcutButtonNumber = d.shortcutButtonNumber
        data.shortcutModifiersRaw = d.shortcutModifiersRaw
        data.shortcutDisplayName = d.shortcutDisplayName
    }

    func clearShortcut() {
        data.shortcutKind = "none"
        data.shortcutKeyCode = 0
        data.shortcutButtonNumber = -1
        data.shortcutModifiersRaw = 0
        data.shortcutDisplayName = ""
    }

    func clearHomeShortcut() {
        data.homeShortcutKind = "none"
        data.homeShortcutKeyCode = 0
        data.homeShortcutButtonNumber = -1
        data.homeShortcutModifiersRaw = 0
        data.homeShortcutDisplayName = ""
    }
}

private enum GlobalBackShortcutFormatter {
    static let relevantModifierMask: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    static func modifierPrefix(_ flags: NSEvent.ModifierFlags) -> String {
        var prefix = ""
        if flags.contains(.control) { prefix += "⌃" }
        if flags.contains(.option) { prefix += "⌥" }
        if flags.contains(.shift) { prefix += "⇧" }
        if flags.contains(.command) { prefix += "⌘" }
        return prefix
    }

    static func formatKeyboard(keyCode: UInt16, characters: String?, flags: NSEvent.ModifierFlags) -> String {
        let normalized = flags.intersection(relevantModifierMask)
        let keyLabel: String
        switch keyCode {
        case 36, 76: keyLabel = "Return"
        case 48: keyLabel = "Tab"
        case 49: keyLabel = "Space"
        case 51: keyLabel = "Delete"
        case 53: keyLabel = "Esc"
        case 117: keyLabel = "Fwd Del"
        case 123: keyLabel = "←"
        case 124: keyLabel = "→"
        case 125: keyLabel = "↓"
        case 126: keyLabel = "↑"
        case 122: keyLabel = "F1"
        case 120: keyLabel = "F2"
        case 99: keyLabel = "F3"
        case 118: keyLabel = "F4"
        case 96: keyLabel = "F5"
        case 97: keyLabel = "F6"
        case 98: keyLabel = "F7"
        case 100: keyLabel = "F8"
        case 101: keyLabel = "F9"
        case 109: keyLabel = "F10"
        case 103: keyLabel = "F11"
        case 111: keyLabel = "F12"
        default:
            let cleaned = (characters ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            keyLabel = cleaned.isEmpty ? "Key \(keyCode)" : cleaned.uppercased()
        }
        return modifierPrefix(normalized) + keyLabel
    }

    static func formatMouse(buttonNumber: Int, flags: NSEvent.ModifierFlags) -> String {
        let normalized = flags.intersection(relevantModifierMask)
        let base: String
        switch buttonNumber {
        case 0: base = "Left Mouse Button"
        case 1: base = "Right Mouse Button"
        case 2: base = "Middle Mouse Button"
        default: base = "Mouse Button \(buttonNumber + 1)"
        }
        let prefix = modifierPrefix(normalized)
        return prefix.isEmpty ? base : "\(prefix) + \(base)"
    }
}

private final class GlobalBackRecorderNSView: NSView {
    var onRecordingChange: ((Bool) -> Void)?
    var onCaptured: ((String, UInt16, Int, UInt, String) -> Void)?
    private var isRecording = false {
        didSet {
            onRecordingChange?(isRecording)
        }
    }
    private var localMonitor: Any?

    deinit {
        stopMonitoring()
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        true
    }

    override func resignFirstResponder() -> Bool {
        if isRecording {
            stopRecording()
        }
        return super.resignFirstResponder()
    }

    override func mouseDown(with event: NSEvent) {
        if !isRecording {
            window?.makeFirstResponder(self)
            startRecording()
        }
    }

    private func startRecording() {
        stopMonitoring()
        isRecording = true
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self, self.isRecording else { return event }
            return self.handleCapturedEvent(event)
        }
    }

    private func stopMonitoring() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }

    private func stopRecording() {
        stopMonitoring()
        isRecording = false
    }

    private func handleCapturedEvent(_ event: NSEvent) -> NSEvent? {
        let flags = event.modifierFlags.intersection(GlobalBackShortcutFormatter.relevantModifierMask)
        switch event.type {
        case .keyDown:
            if event.isARepeat {
                return nil
            }
            let display = GlobalBackShortcutFormatter.formatKeyboard(
                keyCode: event.keyCode,
                characters: event.charactersIgnoringModifiers,
                flags: flags
            )
            onCaptured?("keyboard", event.keyCode, -1, flags.rawValue, display)
            stopRecording()
            return nil
        case .leftMouseDown:
            let pt = convert(event.locationInWindow, from: nil)
            if !bounds.contains(pt) {
                stopRecording()
                return event
            }
            let display = GlobalBackShortcutFormatter.formatMouse(buttonNumber: event.buttonNumber, flags: flags)
            onCaptured?("mouse", 0, event.buttonNumber, flags.rawValue, display)
            stopRecording()
            return nil
        case .rightMouseDown, .otherMouseDown:
            let display = GlobalBackShortcutFormatter.formatMouse(buttonNumber: event.buttonNumber, flags: flags)
            onCaptured?("mouse", 0, event.buttonNumber, flags.rawValue, display)
            stopRecording()
            return nil
        default:
            return event
        }
    }
}

private struct GlobalBackShortcutRecorderRepresentable: NSViewRepresentable {
    @Binding var isRecording: Bool
    var onCaptured: (String, UInt16, Int, UInt, String) -> Void

    func makeNSView(context: Context) -> GlobalBackRecorderNSView {
        let view = GlobalBackRecorderNSView()
        view.onRecordingChange = { recording in
            DispatchQueue.main.async {
                self.isRecording = recording
            }
        }
        view.onCaptured = onCaptured
        return view
    }

    func updateNSView(_ nsView: GlobalBackRecorderNSView, context: Context) {
        nsView.onCaptured = onCaptured
    }
}

struct GlobalBackSettings: View {
    @ObservedObject private var store = GlobalBackSettingsStore.shared
    @State private var isRecordingBack = false
    @State private var isRecordingHome = false

    private var hasUnmodifiedLeftClickWarning: Bool {
        let backWarn = store.data.shortcutEnabled
            && store.data.shortcutKind == "mouse"
            && store.data.shortcutButtonNumber == 0
            && store.data.shortcutModifiersRaw == 0
        let homeWarn = store.data.homeShortcutEnabled
            && store.data.homeShortcutKind == "mouse"
            && store.data.homeShortcutButtonNumber == 0
            && store.data.homeShortcutModifiersRaw == 0
        return backWarn || homeWarn
    }

    private func shortcutSummaryText(isRecording: Bool, kind: String, displayName: String) -> String {
        if isRecording {
            return NSLocalizedString("preferences.globalBack.recordingPrompt", comment: "")
        }
        if kind == "none" || displayName.isEmpty {
            return NSLocalizedString("preferences.globalBack.notSet", comment: "")
        }
        return displayName
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("preferences.globalBack.description")
                    .font(.caption)
                    .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 8) {
                    Text("preferences.globalBack.section.titlebar")
                        .font(.headline)

                    Toggle("preferences.globalBack.titlebarBackEnabled", isOn: $store.data.titlebarBackEnabled)

                    Toggle("preferences.globalBack.onlyWhenNoSidebarBackButton", isOn: $store.data.onlyWhenNoSidebarBackButton)
                        .disabled(!store.data.titlebarBackEnabled)
                        .padding(.leading, 20)

                    Toggle("preferences.globalBack.includeTopCloseButtons", isOn: $store.data.includeTopCloseButtons)

                    Toggle("preferences.globalBack.titlebarHomeEnabled", isOn: $store.data.titlebarHomeEnabled)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("preferences.globalBack.section.shortcut")
                        .font(.headline)

                    Toggle("preferences.globalBack.shortcutEnabled", isOn: $store.data.shortcutEnabled)

                    HStack(spacing: 10) {
                        Text("preferences.globalBack.shortcutLabel")
                            .frame(minWidth: 96, alignment: .leading)

                        ZStack {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(isRecordingBack ? Color.accentColor.opacity(0.14) : Color(NSColor.controlBackgroundColor))
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(isRecordingBack ? Color.accentColor : Color.secondary.opacity(0.35), lineWidth: isRecordingBack ? 1.5 : 1)
                            Text(shortcutSummaryText(isRecording: isRecordingBack,
                                                     kind: store.data.shortcutKind,
                                                     displayName: store.data.shortcutDisplayName))
                                .font(.system(.body, design: .rounded))
                                .foregroundColor(isRecordingBack ? .accentColor : .primary)
                                .lineLimit(1)
                                .padding(.horizontal, 10)
                            GlobalBackShortcutRecorderRepresentable(isRecording: $isRecordingBack) { kind, keyCode, buttonNumber, modifiersRaw, display in
                                store.data.shortcutKind = kind
                                store.data.shortcutKeyCode = keyCode
                                store.data.shortcutButtonNumber = buttonNumber
                                store.data.shortcutModifiersRaw = modifiersRaw
                                store.data.shortcutDisplayName = display
                            }
                        }
                        .frame(height: 28)
                        .help(NSLocalizedString("preferences.globalBack.clickToRecord", comment: ""))
                        .opacity(store.data.shortcutEnabled ? 1.0 : 0.55)
                        .allowsHitTesting(store.data.shortcutEnabled)

                        Button("preferences.globalBack.resetDefault") {
                            store.resetShortcutToDefault()
                        }
                        Button("preferences.globalBack.clear") {
                            store.clearShortcut()
                        }
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("preferences.globalBack.section.homeShortcut")
                        .font(.headline)

                    Toggle("preferences.globalBack.homeShortcutEnabled", isOn: $store.data.homeShortcutEnabled)

                    HStack(spacing: 10) {
                        Text("preferences.globalBack.homeShortcutLabel")
                            .frame(minWidth: 96, alignment: .leading)

                        ZStack {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(isRecordingHome ? Color.accentColor.opacity(0.14) : Color(NSColor.controlBackgroundColor))
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(isRecordingHome ? Color.accentColor : Color.secondary.opacity(0.35), lineWidth: isRecordingHome ? 1.5 : 1)
                            Text(shortcutSummaryText(isRecording: isRecordingHome,
                                                     kind: store.data.homeShortcutKind,
                                                     displayName: store.data.homeShortcutDisplayName))
                                .font(.system(.body, design: .rounded))
                                .foregroundColor(isRecordingHome ? .accentColor : .primary)
                                .lineLimit(1)
                                .padding(.horizontal, 10)
                            GlobalBackShortcutRecorderRepresentable(isRecording: $isRecordingHome) { kind, keyCode, buttonNumber, modifiersRaw, display in
                                store.data.homeShortcutKind = kind
                                store.data.homeShortcutKeyCode = keyCode
                                store.data.homeShortcutButtonNumber = buttonNumber
                                store.data.homeShortcutModifiersRaw = modifiersRaw
                                store.data.homeShortcutDisplayName = display
                            }
                        }
                        .frame(height: 28)
                        .help(NSLocalizedString("preferences.globalBack.clickToRecord", comment: ""))
                        .opacity(store.data.homeShortcutEnabled ? 1.0 : 0.55)
                        .allowsHitTesting(store.data.homeShortcutEnabled)

                        Button("preferences.globalBack.clear") {
                            store.clearHomeShortcut()
                        }
                    }
                }

                if hasUnmodifiedLeftClickWarning {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("preferences.globalBack.warning.unmodifiedLeftClick")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
            }
            .padding(20)
        }
        .frame(width: 600, height: 420, alignment: .topLeading)
    }
}

struct PlayCoverSettingsView: View {
    @ObservedObject var updaterViewModel: UpdaterViewModel
    @EnvironmentObject var storeVM: StoreVM

    private enum Tabs: Hashable {
        case updates, ipasource, keyCover, globalBack, install, uninstall
    }

    var body: some View {
        TabView {
            UpdateSettings(updaterViewModel: updaterViewModel)
                .tabItem {
                    Label("preferences.tab.updates", systemImage: "square.and.arrow.down")
                }
                .tag(Tabs.updates)
            IPASourceSettings()
                .tabItem {
                    Label("preferences.tab.ipasource", systemImage: "list.bullet")
                }
                .tag(Tabs.ipasource)
                .environmentObject(storeVM)
            KeyCoverSettings.shared
                .tabItem {
                    Label("KeyCover", systemImage: "key.fill")
                }
                .tag(Tabs.keyCover)
            GlobalBackSettings()
                .tabItem {
                    Label("preferences.tab.globalBack", systemImage: "chevron.backward.circle")
                }
                .tag(Tabs.globalBack)
            InstallSettings.shared
                .tabItem {
                    Label("preferences.tab.install", systemImage: "arrow.down.app")
                }
                .tag(Tabs.install)
            UninstallSettings.shared
                .tabItem {
                  Label("preferences.tab.uninstall", systemImage: "trash.square")
                }
                .tag(Tabs.uninstall)
        }
    }
}
