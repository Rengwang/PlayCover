//
//  AppSettings.swift
//  PlayCover
//

import AppKit
import Foundation
import UniformTypeIdentifiers

struct AppSettingsData: Codable {
    var bundleIdentifier: String = ""

    var keymapping = false
    var sensitivity: Float = 50

    var disableTimeout = false
    var displayRotation = 0
    var iosDeviceModel = "iPhone19,4"
    var windowWidth = 1920
    var windowHeight = 1080
    var customScaler = 2.0
    var resolution = 7
    var aspectRatio = 1
    var notch: Bool = NSScreen.hasNotch()
    var bypass = false
    var discordActivity = DiscordActivity()
    var version = "3.0.0"
    var playChain = true
    var playChainDebugging = false
    var inverseScreenValues = false
    var metalHUD = false {
        didSet {
            do {
                try Shell.setMetalHUD(bundleIdentifier, enabled: metalHUD)
            } catch {
                Log.shared.error(error)
            }
        }
    }
    var windowFixMethod = 0
    var injectIntrospection = false
    var rootWorkDir = true
    var noKMOnInput = true
    var enableScrollWheel = true
    var scrollWheelSpeed: Float = 4
    var optionScrollZoom = true
    var touchAlternatives = true
    var hideTitleBar = true
    var floatingWindow = false
    var checkMicPermissionSync = false
    var limitMotionUpdateFrequency = false
    var disableBuiltinMouse = false
    var resizableAspectRatioType = 0
    var resizableAspectRatioWidth = 0
    var resizableAspectRatioHeight = 0
    var blockSleepSpamming = false
    var ignoreUnityKeyboardInitializationError = false
    var uiScale: Double = 1.0
    var appearanceStyle: Int = 0
    var layoutIdiom: Int = 3
    var duoVerticalBar = false
    var sdkShift = false
    var useNativePlatform = false
    var cameraRotation = -1
    var cameraFrontMirror = -1
    var cameraBackMirror = -1
    var spoofPowerState = false {
        didSet {
            if spoofPowerState {
                if powerStatePolicy != 1 {
                    powerStatePolicy = 1
                }
            } else if powerStatePolicy == 1 {
                powerStatePolicy = 0
            }
        }
    }
    var powerSavingMode: Bool = false
    var memorySavingMode: Bool = false
    var powerStatePolicy: Int = 0 {
        didSet {
            let legacySpoof = (powerStatePolicy == 1)
            if spoofPowerState != legacySpoof {
                spoofPowerState = legacySpoof
            }
        }
    }
    var frameRateCap: Int = 0
    var fpsOverlay: Bool = false
    var metalMemorySaver: Bool = false
    var avMediaSaver: Bool = false
    var blockSplashAds = true
    var mockLocationEnabled = false
    var mockLocationLatitude: Double = 39.9042
    var mockLocationLongitude: Double = 116.4074
    var mockLocationName: String = "Beijing"
    /// Cached result of the anti-tamper scan: matcher version + per-binary fingerprint.
    var machoTrapSchemaVersion = 0
    var machoScanFingerprint = ""
    var machoScanDirToken = ""

    init() {}

    // handle old 2.x settings where PlayChain did not exist yet
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bundleIdentifier = try container.decodeIfPresent(String.self, forKey: .bundleIdentifier) ?? ""
        keymapping = try container.decodeIfPresent(Bool.self, forKey: .keymapping) ?? false
        sensitivity = try container.decodeIfPresent(Float.self, forKey: .sensitivity) ?? 50
        disableTimeout = try container.decodeIfPresent(Bool.self, forKey: .disableTimeout) ?? false
        displayRotation = try container.decodeIfPresent(Int.self, forKey: .displayRotation) ?? 0
        iosDeviceModel = try container.decodeIfPresent(String.self, forKey: .iosDeviceModel) ?? "iPhone19,4"
        windowWidth = try container.decodeIfPresent(Int.self, forKey: .windowWidth) ?? 1920
        windowHeight = try container.decodeIfPresent(Int.self, forKey: .windowHeight) ?? 1080
        customScaler = try container.decodeIfPresent(Double.self, forKey: .customScaler) ?? 2.0
        resolution = try container.decodeIfPresent(Int.self, forKey: .resolution) ?? 7
        aspectRatio = try container.decodeIfPresent(Int.self, forKey: .aspectRatio) ?? 1
        notch = try container.decodeIfPresent(Bool.self, forKey: .notch) ?? NSScreen.hasNotch()
        bypass = try container.decodeIfPresent(Bool.self, forKey: .bypass) ?? false
        discordActivity = try container.decodeIfPresent(DiscordActivity.self,
                                                        forKey: .discordActivity) ?? DiscordActivity()
        version = try container.decodeIfPresent(String.self, forKey: .version) ?? "3.0.0"
        playChain = try container.decodeIfPresent(Bool.self, forKey: .playChain) ?? true
        playChainDebugging = try container.decodeIfPresent(Bool.self, forKey: .playChainDebugging) ?? false
        inverseScreenValues = try container.decodeIfPresent(Bool.self, forKey: .inverseScreenValues) ?? false
        metalHUD = try container.decodeIfPresent(Bool.self, forKey: .metalHUD) ?? false
        windowFixMethod = try container.decodeIfPresent(Int.self, forKey: .windowFixMethod) ?? 0
        injectIntrospection = try container.decodeIfPresent(Bool.self, forKey: .injectIntrospection) ?? false
        rootWorkDir = try container.decodeIfPresent(Bool.self, forKey: .rootWorkDir) ?? true
        noKMOnInput = try container.decodeIfPresent(Bool.self, forKey: .noKMOnInput) ?? true
        enableScrollWheel = try container.decodeIfPresent(Bool.self, forKey: .enableScrollWheel) ?? true
        scrollWheelSpeed = try container.decodeIfPresent(Float.self, forKey: .scrollWheelSpeed) ?? 4
        optionScrollZoom = try container.decodeIfPresent(Bool.self, forKey: .optionScrollZoom) ?? true
        touchAlternatives = try container.decodeIfPresent(Bool.self, forKey: .touchAlternatives) ?? true
        hideTitleBar = try container.decodeIfPresent(Bool.self, forKey: .hideTitleBar) ?? true
        floatingWindow = try container.decodeIfPresent(Bool.self, forKey: .floatingWindow) ?? false
        checkMicPermissionSync = try container.decodeIfPresent(Bool.self, forKey: .checkMicPermissionSync) ?? false
        limitMotionUpdateFrequency = try container.decodeIfPresent(Bool.self,
                                                                   forKey: .limitMotionUpdateFrequency) ?? false
        disableBuiltinMouse = try container.decodeIfPresent(Bool.self, forKey: .disableBuiltinMouse) ?? false
        resizableAspectRatioType = try container.decodeIfPresent(Int.self, forKey: .resizableAspectRatioType) ?? 0
        resizableAspectRatioWidth = try container.decodeIfPresent(Int.self, forKey: .resizableAspectRatioWidth) ?? 0
        resizableAspectRatioHeight = try container.decodeIfPresent(Int.self, forKey: .resizableAspectRatioHeight) ?? 0
        blockSleepSpamming = try container.decodeIfPresent(Bool.self, forKey: .blockSleepSpamming) ?? false
        ignoreUnityKeyboardInitializationError = try container.decodeIfPresent(
            Bool.self, forKey: .ignoreUnityKeyboardInitializationError) ?? false
        let decodedUIScale = try container.decodeIfPresent(Double.self, forKey: .uiScale) ?? 1.0
        uiScale = decodedUIScale <= 0.0 ? 1.0 : decodedUIScale
        let decodedAppearanceStyle = try container.decodeIfPresent(Int.self, forKey: .appearanceStyle) ?? 0
        appearanceStyle = (0...2).contains(decodedAppearanceStyle) ? decodedAppearanceStyle : 0
        layoutIdiom = try container.decodeIfPresent(Int.self, forKey: .layoutIdiom) ?? 3
        duoVerticalBar = try container.decodeIfPresent(Bool.self, forKey: .duoVerticalBar) ?? false
        sdkShift = try container.decodeIfPresent(Bool.self, forKey: .sdkShift) ?? false
        useNativePlatform = try container.decodeIfPresent(Bool.self, forKey: .useNativePlatform) ?? false
        cameraRotation = try container.decodeIfPresent(Int.self, forKey: .cameraRotation) ?? -1
        cameraFrontMirror = try container.decodeIfPresent(Int.self, forKey: .cameraFrontMirror) ?? -1
        cameraBackMirror = try container.decodeIfPresent(Int.self, forKey: .cameraBackMirror) ?? -1
        let legacySpoofPowerState = try container.decodeIfPresent(Bool.self, forKey: .spoofPowerState) ?? false
        if let decodedPolicy = try container.decodeIfPresent(Int.self, forKey: .powerStatePolicy) {
            powerStatePolicy = (0...2).contains(decodedPolicy) ? decodedPolicy : 0
        } else {
            powerStatePolicy = legacySpoofPowerState ? 1 : 0
        }
        spoofPowerState = (powerStatePolicy == 1)
        powerSavingMode = try container.decodeIfPresent(Bool.self, forKey: .powerSavingMode) ?? false
        memorySavingMode = try container.decodeIfPresent(Bool.self, forKey: .memorySavingMode) ?? false
        let decodedFrameRateCap = try container.decodeIfPresent(Int.self, forKey: .frameRateCap) ?? 0
        frameRateCap = [-1, 0, 10, 20, 30, 40, 45, 60].contains(decodedFrameRateCap) ? decodedFrameRateCap : 0
        fpsOverlay = try container.decodeIfPresent(Bool.self, forKey: .fpsOverlay) ?? false
        metalMemorySaver = try container.decodeIfPresent(Bool.self, forKey: .metalMemorySaver) ?? false
        avMediaSaver = try container.decodeIfPresent(Bool.self, forKey: .avMediaSaver) ?? false
        blockSplashAds = try container.decodeIfPresent(Bool.self, forKey: .blockSplashAds) ?? true
        mockLocationEnabled = try container.decodeIfPresent(Bool.self, forKey: .mockLocationEnabled) ?? false
        mockLocationLatitude = try container.decodeIfPresent(Double.self, forKey: .mockLocationLatitude) ?? 39.9042
        mockLocationLongitude = try container.decodeIfPresent(Double.self, forKey: .mockLocationLongitude) ?? 116.4074
        mockLocationName = try container.decodeIfPresent(String.self, forKey: .mockLocationName) ?? "Beijing"
        machoTrapSchemaVersion = try container.decodeIfPresent(Int.self,
                                                               forKey: .machoTrapSchemaVersion) ?? 0
        machoScanFingerprint = try container.decodeIfPresent(String.self,
                                                             forKey: .machoScanFingerprint) ?? ""
        machoScanDirToken = try container.decodeIfPresent(String.self,
                                                          forKey: .machoScanDirToken) ?? ""
    }
}

class AppSettings: ObservableObject {
    static var appSettingsDir: URL {
        let settingsFolder =
            PlayTools.playCoverContainer.appendingPathComponent("App Settings")
        if !FileManager.default.fileExists(atPath: settingsFolder.path) {
            do {
                try FileManager.default.createDirectory(at: settingsFolder,
                                                        withIntermediateDirectories: true,
                                                        attributes: [:])
            } catch {
                Log.shared.error(error)
            }
        }
        return settingsFolder
    }

    let info: AppInfo
    let settingsUrl: URL
    var openWithLLDB: Bool = false {
        willSet {
            objectWillChange.send()
        }
    }
    var openLLDBWithTerminal: Bool = true {
        willSet {
            objectWillChange.send()
        }
    }
    private var suppressPersistence = false
    var settings: AppSettingsData {
        willSet {
            objectWillChange.send()
        }
        didSet {
            if !suppressPersistence {
                encode()
                if oldValue.touchAlternatives != settings.touchAlternatives {
                    let bundleID = settings.bundleIdentifier.isEmpty ? info.bundleIdentifier : settings.bundleIdentifier
                    let enabled = settings.touchAlternatives
                    DispatchQueue.global(qos: .utility).async {
                        Shell.setTouchAlternatives(bundleID, enabled: enabled)
                    }
                }
            }
        }
    }

    init(_ info: AppInfo) {
        self.info = info
        settingsUrl = AppSettings.appSettingsDir.appendingPathComponent(info.bundleIdentifier)
                                                .appendingPathExtension("plist")
        var defaults = AppSettingsData()
        defaults.bundleIdentifier = info.bundleIdentifier
        Self.applySmartAdaptDefaults(to: &defaults, info: info)
        settings = defaults
        if !decode() {
            preserveUnreadableSettingsIfPresent()
            encode()
            let bundleID = info.bundleIdentifier
            let enabled = settings.touchAlternatives
            DispatchQueue.global(qos: .utility).async {
                Shell.setTouchAlternatives(bundleID, enabled: enabled)
            }
        }

        if settings.bundleIdentifier != info.bundleIdentifier {
            settings.bundleIdentifier = info.bundleIdentifier
        }
    }

    static func applySmartAdaptDefaults(to data: inout AppSettingsData, info: AppInfo) {
        guard data.resolution == 7 else { return }
        if info.supportsAdaptiveWindowLayout(forceSDKShift: data.sdkShift) {
            data.resizableAspectRatioType = 0
            data.resizableAspectRatioWidth = 0
            data.resizableAspectRatioHeight = 0
            data.windowWidth = 900
            data.windowHeight = 760
        } else {
            let ratio = info.recommendedAspectRatio
            let logicalRes = info.recommendedLogicalResolution
            data.resizableAspectRatioType = 1
            data.resizableAspectRatioWidth = ratio.width
            data.resizableAspectRatioHeight = ratio.height
            data.windowWidth = logicalRes.width
            data.windowHeight = logicalRes.height
        }
    }

    func applySmartAdaptDefaults(to data: inout AppSettingsData) {
        Self.applySmartAdaptDefaults(to: &data, info: info)
    }

    public func sync() {
        var updatedSettings = settings
        updatedSettings.notch = NSScreen.hasNotch()
        if updatedSettings.resolution == 1 {
            let resolution = AppSettings.autoResolution()
            updatedSettings.windowWidth = resolution.width
            updatedSettings.windowHeight = resolution.height
        } else if updatedSettings.resolution == 7 {
            applySmartAdaptDefaults(to: &updatedSettings)
        }
        if updatedSettings.notch != settings.notch
            || updatedSettings.windowWidth != settings.windowWidth
            || updatedSettings.windowHeight != settings.windowHeight
            || updatedSettings.resizableAspectRatioType != settings.resizableAspectRatioType
            || updatedSettings.resizableAspectRatioWidth != settings.resizableAspectRatioWidth
            || updatedSettings.resizableAspectRatioHeight != settings.resizableAspectRatioHeight {
            settings = updatedSettings
        }
    }

    static func autoResolution() -> (width: Int, height: Int) {
        let width = Int(NSScreen.main?.frame.width ?? 1920)
        let height = Int(NSScreen.main?.frame.height ?? 1080)
        let wFloat = Float(width)
        let hFloat = Float(height)
        if NSScreen.hasNotch() && (hFloat/wFloat)*16.0 > 10.3 && (hFloat/wFloat)*16.0 < 10.4 {
            return (width, Int((wFloat / 16) * 10))
        } else {
            return (width, height)
        }
    }

    public func reset() {
        var defaults = AppSettingsData()
        defaults.bundleIdentifier = info.bundleIdentifier
        applySmartAdaptDefaults(to: &defaults)
        settings = defaults
    }

    @discardableResult
    public func decode() -> Bool {
        do {
            let data = try Data(contentsOf: settingsUrl)
            let decoded = try PropertyListDecoder().decode(AppSettingsData.self, from: data)
            suppressPersistence = true
            settings = decoded
            suppressPersistence = false
            return true
        } catch {
            suppressPersistence = false
            if FileManager.default.fileExists(atPath: settingsUrl.path) {
                Log.shared.log(
                    "App settings decode failed for \(info.bundleIdentifier): \(error.localizedDescription)",
                    isError: true
                )
            }
            return false
        }
    }

    @discardableResult
    public func encode() -> Bool {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml

        do {
            let data = try encoder.encode(settings)
            try data.write(to: settingsUrl, options: .atomic)
            return true
        } catch {
            Log.shared.log(
                "App settings write failed for \(info.bundleIdentifier): \(error.localizedDescription)",
                isError: true
            )
            return false
        }
    }

    private func preserveUnreadableSettingsIfPresent() {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: settingsUrl.path) else { return }
        let backupURL = settingsUrl.deletingPathExtension().appendingPathExtension("invalid.plist")
        do {
            try? fileManager.removeItem(at: backupURL)
            try fileManager.copyItem(at: settingsUrl, to: backupURL)
            Log.shared.log("Preserved unreadable app settings at \(backupURL.path)", isError: true)
        } catch {
            Log.shared.log(
                "Failed to preserve unreadable app settings for \(info.bundleIdentifier): " +
                    error.localizedDescription,
                isError: true
            )
        }
    }
}

extension NSScreen {
    public static func hasNotch() -> Bool {
        guard #available(macOS 12, *) else { return false }
        // check if any of the connected screens contains a notch
        return NSScreen.screens.contains { $0.safeAreaInsets.top != 0 }
    }

    private static func getMacModel() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        var modelIdentifier: String?

        if let modelData = IORegistryEntryCreateCFProperty(service, "model" as CFString, kCFAllocatorDefault, 0)
            .takeRetainedValue() as? Data {
            if let modelIdentifierCString = String(data: modelData, encoding: .utf8)?.cString(using: .utf8) {
                modelIdentifier = String(cString: modelIdentifierCString)
            }
        }
        IOObjectRelease(service)
        return modelIdentifier
    }
}
