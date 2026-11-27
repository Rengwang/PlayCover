// swiftlint:disable file_length
//
//  FeatureManagerView.swift
//  PlayCover
//

import SwiftUI

private enum ManagedFeatureSection: String, CaseIterable, Identifiable {
    case layoutDisplay
    case performanceEfficiency
    case camera
    case privacyExperience
    case inputControls
    case compatibilitySystem

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .layoutDisplay: return "featureManager.section.layoutDisplay"
        case .performanceEfficiency: return "featureManager.section.performanceEfficiency"
        case .camera: return "featureManager.section.camera"
        case .privacyExperience: return "featureManager.section.privacyExperience"
        case .inputControls: return "featureManager.section.inputControls"
        case .compatibilitySystem: return "featureManager.section.compatibilitySystem"
        }
    }

    var items: [ManagedSettingItem] {
        switch self {
        case .layoutDisplay:
            return [
                .picker(.layoutIdiom),
                .toggle(.duoVerticalBar),
                .picker(.resolution),
                .picker(.uiScale),
                .picker(.appearanceStyle),
                .picker(.displayRotation),
                .toggle(.hideTitleBar),
                .toggle(.floatingWindow),
                .toggle(.disableTimeout),
                .toggle(.metalHUD)
            ]
        case .performanceEfficiency:
            return [
                .toggle(.powerSavingMode),
                .toggle(.memorySavingMode),
                .picker(.powerStatePolicy),
                .picker(.frameRateCap),
                .toggle(.metalMemorySaver),
                .toggle(.avMediaSaver)
            ]
        case .camera:
            return [
                .picker(.cameraRotation),
                .picker(.cameraFrontMirror),
                .picker(.cameraBackMirror)
            ]
        case .privacyExperience:
            return [
                .toggle(.blockSplashAds),
                .toggle(.mockLocationEnabled),
                .toggle(.playChain),
                .toggle(.bypass)
            ]
        case .inputControls:
            return [
                .toggle(.touchAlternatives),
                .toggle(.keymapping),
                .toggle(.noKMOnInput),
                .toggle(.enableScrollWheel),
                .toggle(.optionScrollZoom),
                .toggle(.disableBuiltinMouse)
            ]
        case .compatibilitySystem:
            return [
                .toggle(.blockSleepSpamming),
                .toggle(.sdkShift),
                .toggle(.useNativePlatform),
                .toggle(.checkMicPermissionSync),
                .toggle(.limitMotionUpdateFrequency),
                .toggle(.rootWorkDir)
            ]
        }
    }
}

private enum ManagedSettingItem: Hashable, Identifiable {
    case toggle(ManagedToggleFeature)
    case picker(ManagedPickerFeature)

    var id: String {
        switch self {
        case .toggle(let feature): return "toggle.\(feature.rawValue)"
        case .picker(let feature): return "picker.\(feature.rawValue)"
        }
    }

    var rawKey: String {
        switch self {
        case .toggle(let feature): return feature.rawValue
        case .picker(let feature): return feature.rawValue
        }
    }

    var titleKey: String {
        switch self {
        case .toggle(let feature): return feature.titleKey
        case .picker(let feature): return feature.titleKey
        }
    }

    var descriptionKey: String {
        switch self {
        case .toggle(let feature): return feature.descriptionKey
        case .picker(let feature): return feature.descriptionKey
        }
    }

    var localizedTitle: String {
        NSLocalizedString(titleKey, comment: "")
    }

    var localizedDescription: String {
        NSLocalizedString(descriptionKey, comment: "")
    }

    var symbolName: String {
        switch self {
        case .toggle(let feature): return feature.symbolName
        case .picker(let feature): return feature.symbolName
        }
    }

    var badgeColor: Color {
        switch self {
        case .toggle(let feature): return feature.badgeColor
        case .picker(let feature): return feature.badgeColor
        }
    }
}

private struct ManagedPickerOption: Identifiable, Hashable {
    let id: String
    let labelKey: String?
    let literalLabel: String?

    init(id: String, labelKey: String) {
        self.id = id
        self.labelKey = labelKey
        self.literalLabel = nil
    }

    init(id: String, literal: String) {
        self.id = id
        self.labelKey = nil
        self.literalLabel = literal
    }

    var displayText: String {
        if let labelKey = labelKey {
            return NSLocalizedString(labelKey, comment: "")
        }
        return literalLabel ?? id
    }
}

private enum ManagedPickerFeature: String, CaseIterable, Identifiable {
    case layoutIdiom
    case resolution
    case uiScale
    case appearanceStyle
    case displayRotation
    case powerStatePolicy
    case frameRateCap
    case cameraRotation
    case cameraFrontMirror
    case cameraBackMirror

    var id: String { rawValue }
    var titleKey: String { "featureManager.feature.\(rawValue).title" }
    var descriptionKey: String { "featureManager.feature.\(rawValue).desc" }

    var symbolName: String {
        switch self {
        case .layoutIdiom: return "rectangle.split.2x1.fill"
        case .resolution: return "display"
        case .uiScale: return "textformat.size"
        case .appearanceStyle: return "moon.circle.fill"
        case .displayRotation: return "rotate.right.fill"
        case .powerStatePolicy: return "battery.100"
        case .frameRateCap: return "speedometer"
        case .cameraRotation: return "camera.rotate.fill"
        case .cameraFrontMirror: return "camera.fill"
        case .cameraBackMirror: return "video.fill"
        }
    }

    var badgeColor: Color {
        switch self {
        case .layoutIdiom: return .blue
        case .resolution: return .indigo
        case .uiScale: return .purple
        case .appearanceStyle: return .indigo
        case .displayRotation: return .cyan
        case .powerStatePolicy: return .green
        case .frameRateCap: return .blue
        case .cameraRotation: return .green
        case .cameraFrontMirror: return .teal
        case .cameraBackMirror: return .mint
        }
    }

    var defaultValue: String {
        switch self {
        case .layoutIdiom: return "3"
        case .resolution: return "7"
        case .uiScale: return "1.0"
        case .appearanceStyle: return "0"
        case .displayRotation: return "0"
        case .powerStatePolicy: return "0"
        case .frameRateCap: return "0"
        case .cameraRotation: return "-1"
        case .cameraFrontMirror: return "-1"
        case .cameraBackMirror: return "-1"
        }
    }

    var options: [ManagedPickerOption] {
        switch self {
        case .layoutIdiom:
            return [
                ManagedPickerOption(id: "3", labelKey: "featureManager.option.layoutIdiom.3"),
                ManagedPickerOption(id: "1", labelKey: "featureManager.option.layoutIdiom.1"),
                ManagedPickerOption(id: "2", labelKey: "featureManager.option.layoutIdiom.2"),
                ManagedPickerOption(id: "0", labelKey: "featureManager.option.layoutIdiom.0")
            ]
        case .resolution:
            return [
                ManagedPickerOption(id: "7", labelKey: "featureManager.option.resolution.7"),
                ManagedPickerOption(id: "6", labelKey: "featureManager.option.resolution.6"),
                ManagedPickerOption(id: "1", labelKey: "featureManager.option.resolution.1"),
                ManagedPickerOption(id: "2", literal: "1080p"),
                ManagedPickerOption(id: "3", literal: "1440p"),
                ManagedPickerOption(id: "4", literal: "4K")
            ]
        case .uiScale:
            return [
                ManagedPickerOption(id: "1.0", labelKey: "featureManager.option.uiScale.1.0"),
                ManagedPickerOption(id: "0.77", labelKey: "featureManager.option.uiScale.0.77"),
                ManagedPickerOption(id: "1.15", literal: "115%"),
                ManagedPickerOption(id: "1.25", literal: "125%"),
                ManagedPickerOption(id: "1.5", literal: "150%"),
                ManagedPickerOption(id: "2.0", literal: "200%")
            ]
        case .appearanceStyle:
            return [
                ManagedPickerOption(id: "0", labelKey: "featureManager.option.appearanceStyle.0"),
                ManagedPickerOption(id: "1", labelKey: "featureManager.option.appearanceStyle.1"),
                ManagedPickerOption(id: "2", labelKey: "featureManager.option.appearanceStyle.2")
            ]
        case .displayRotation:
            return [
                ManagedPickerOption(id: "0", labelKey: "settings.settings.displayRotation.default"),
                ManagedPickerOption(id: "1", labelKey: "settings.settings.displayRotation.portrait"),
                ManagedPickerOption(id: "2", labelKey: "settings.settings.displayRotation.landscapeRight"),
                ManagedPickerOption(id: "3", labelKey: "settings.settings.displayRotation.portraitUpsideDown"),
                ManagedPickerOption(id: "4", labelKey: "settings.settings.displayRotation.flipFix")
            ]
        case .powerStatePolicy:
            return [
                ManagedPickerOption(id: "0", labelKey: "featureManager.option.powerStatePolicy.0"),
                ManagedPickerOption(id: "1", labelKey: "featureManager.option.powerStatePolicy.1"),
                ManagedPickerOption(id: "2", labelKey: "featureManager.option.powerStatePolicy.2")
            ]
        case .frameRateCap:
            return [
                ManagedPickerOption(id: "0", labelKey: "featureManager.option.frameRateCap.0"),
                ManagedPickerOption(id: "60", literal: "60 FPS"),
                ManagedPickerOption(id: "30", literal: "30 FPS")
            ]
        case .cameraRotation:
            return [
                ManagedPickerOption(id: "-1", labelKey: "featureManager.option.cameraRotation.auto"),
                ManagedPickerOption(id: "-2", labelKey: "featureManager.option.cameraRotation.app"),
                ManagedPickerOption(id: "0", literal: "0°"),
                ManagedPickerOption(id: "90", literal: "90°"),
                ManagedPickerOption(id: "180", literal: "180°"),
                ManagedPickerOption(id: "270", literal: "270°")
            ]
        case .cameraFrontMirror, .cameraBackMirror:
            return [
                ManagedPickerOption(id: "-1", labelKey: "featureManager.option.cameraMirror.auto"),
                ManagedPickerOption(id: "1", labelKey: "featureManager.option.cameraMirror.on"),
                ManagedPickerOption(id: "0", labelKey: "featureManager.option.cameraMirror.off")
            ]
        }
    }

    func optionsIncludingCurrent(_ currentValue: String) -> [ManagedPickerOption] {
        if options.contains(where: { $0.id == currentValue }) {
            return options
        }
        return options + [ManagedPickerOption(id: currentValue, literal: fallbackLabel(for: currentValue))]
    }

    func displayLabel(for value: String) -> String {
        if let option = options.first(where: { $0.id == value }) {
            return option.displayText
        }
        return fallbackLabel(for: value)
    }

    private func fallbackLabel(for value: String) -> String {
        switch self {
        case .resolution where value == "0":
            return NSLocalizedString("settings.picker.adaptiveRes.0", comment: "")
        case .resolution where value == "5":
            return NSLocalizedString("settings.picker.adaptiveRes.5", comment: "")
        case .uiScale:
            if let doubleVal = Double(value) {
                return "\(Int(round(doubleVal * 100)))%"
            }
            return value
        default:
            return value
        }
    }

    func currentValue(in data: AppSettingsData) -> String {
        switch self {
        case .layoutIdiom:
            return String(data.layoutIdiom)
        case .resolution:
            return String(data.resolution)
        case .uiScale:
            let known: [(Double, String)] = [
                (1.0, "1.0"), (0.77, "0.77"), (1.15, "1.15"),
                (1.25, "1.25"), (1.5, "1.5"), (2.0, "2.0")
            ]
            if let match = known.first(where: { abs(data.uiScale - $0.0) < 0.005 }) {
                return match.1
            }
            return String(format: "%.2f", data.uiScale)
        case .appearanceStyle:
            return String(data.appearanceStyle)
        case .displayRotation:
            return String(data.displayRotation)
        case .powerStatePolicy:
            return String(data.powerStatePolicy)
        case .frameRateCap:
            return String(data.frameRateCap)
        case .cameraRotation:
            return String(data.cameraRotation)
        case .cameraFrontMirror:
            return String(data.cameraFrontMirror)
        case .cameraBackMirror:
            return String(data.cameraBackMirror)
        }
    }

    private var intKeyPath: WritableKeyPath<AppSettingsData, Int>? {
        switch self {
        case .layoutIdiom: return \.layoutIdiom
        case .resolution: return \.resolution
        case .uiScale: return nil
        case .appearanceStyle: return \.appearanceStyle
        case .displayRotation: return \.displayRotation
        case .powerStatePolicy: return \.powerStatePolicy
        case .frameRateCap: return \.frameRateCap
        case .cameraRotation: return \.cameraRotation
        case .cameraFrontMirror: return \.cameraFrontMirror
        case .cameraBackMirror: return \.cameraBackMirror
        }
    }

    func apply(value: String, to updated: inout AppSettingsData, app: PlayApp) -> Bool {
        guard currentValue(in: updated) != value else { return false }
        if self == .uiScale {
            guard let scale = Double(value) else { return false }
            updated.uiScale = scale
            return true
        }
        guard let keyPath = intKeyPath, let intValue = Int(value) else { return false }
        updated[keyPath: keyPath] = intValue
        if self == .layoutIdiom {
            Self.syncDeviceModel(for: intValue, in: &updated)
        } else if self == .resolution {
            Self.applyResolutionSideEffects(mode: intValue, to: &updated, app: app)
        } else if self == .powerStatePolicy {
            updated.spoofPowerState = (intValue == 1)
        }
        return true
    }

    private static func syncDeviceModel(for idiom: Int, in data: inout AppSettingsData) {
        switch idiom {
        case 3:
            data.iosDeviceModel = "iPhone19,4"
        case 1:
            if !data.iosDeviceModel.hasPrefix("iPhone") || data.iosDeviceModel == "iPhone19,4" {
                data.iosDeviceModel = "iPhone17,2"
            }
        case 2:
            if !data.iosDeviceModel.hasPrefix("iPad") {
                data.iosDeviceModel = "iPad16,6"
            }
        case 0:
            if data.iosDeviceModel.hasPrefix("iPhone") {
                data.iosDeviceModel = "iPad13,8"
            }
        default:
            break
        }
    }

    private static func applyResolutionSideEffects(mode: Int, to data: inout AppSettingsData, app: PlayApp) {
        switch mode {
        case 1:
            let resolution = AppSettings.autoResolution()
            data.windowWidth = resolution.width
            data.windowHeight = resolution.height
        case 2:
            data.windowHeight = 1080
            data.windowWidth = widthForAspectRatio(1080, aspectRatio: data.aspectRatio)
        case 3:
            data.windowHeight = 1440
            data.windowWidth = widthForAspectRatio(1440, aspectRatio: data.aspectRatio)
        case 4:
            data.windowHeight = 2160
            data.windowWidth = widthForAspectRatio(2160, aspectRatio: data.aspectRatio)
        case 7:
            app.settings.applySmartAdaptDefaults(to: &data)
        default:
            break
        }
    }

    private static func widthForAspectRatio(_ height: Int, aspectRatio: Int) -> Int {
        switch aspectRatio {
        case 0: return (height / 3) * 4
        case 2: return (height / 10) * 16
        default: return (height / 9) * 16
        }
    }
}

private enum ManagedToggleFeature: String, CaseIterable, Identifiable {
    case duoVerticalBar
    case hideTitleBar
    case powerSavingMode
    case memorySavingMode
    case metalMemorySaver
    case avMediaSaver
    case blockSplashAds
    case mockLocationEnabled
    case floatingWindow
    case keymapping
    case noKMOnInput
    case enableScrollWheel
    case optionScrollZoom
    case touchAlternatives
    case disableBuiltinMouse
    case disableTimeout
    case playChain
    case bypass
    case blockSleepSpamming
    case sdkShift
    case useNativePlatform
    case checkMicPermissionSync
    case limitMotionUpdateFrequency
    case rootWorkDir
    case metalHUD

    var id: String { rawValue }
    var titleKey: String { "featureManager.feature.\(rawValue).title" }
    var descriptionKey: String { "featureManager.feature.\(rawValue).desc" }

    var symbolName: String {
        switch self {
        case .duoVerticalBar: return "sidebar.right"
        case .hideTitleBar: return "macwindow"
        case .powerSavingMode: return "leaf.fill"
        case .memorySavingMode: return "memorychip"
        case .metalMemorySaver: return "square.stack.3d.up.fill"
        case .avMediaSaver: return "play.rectangle.fill"
        case .blockSplashAds: return "hand.raised.fill"
        case .mockLocationEnabled: return "location.fill"
        case .floatingWindow: return "pin.fill"
        case .keymapping: return "keyboard"
        case .noKMOnInput: return "text.cursor"
        case .enableScrollWheel: return "arrow.up.arrow.down"
        case .optionScrollZoom: return "plus.magnifyingglass"
        case .touchAlternatives: return "hand.draw.fill"
        case .disableBuiltinMouse: return "magicmouse.fill"
        case .disableTimeout: return "sun.max.fill"
        case .playChain: return "key.fill"
        case .bypass: return "lock.shield.fill"
        case .blockSleepSpamming: return "moon.zzz.fill"
        case .sdkShift: return "cpu"
        case .useNativePlatform: return "desktopcomputer"
        case .checkMicPermissionSync: return "mic.fill"
        case .limitMotionUpdateFrequency: return "gyroscope"
        case .rootWorkDir: return "folder.fill"
        case .metalHUD: return "speedometer"
        }
    }

    var badgeColor: Color {
        switch self {
        case .duoVerticalBar: return .teal
        case .hideTitleBar: return .blue
        case .powerSavingMode: return .green
        case .memorySavingMode: return .teal
        case .metalMemorySaver: return .indigo
        case .avMediaSaver: return .orange
        case .blockSplashAds: return .red
        case .mockLocationEnabled: return .blue
        case .floatingWindow: return .indigo
        case .keymapping: return .purple
        case .noKMOnInput: return .teal
        case .enableScrollWheel: return .cyan
        case .optionScrollZoom: return .blue
        case .touchAlternatives: return .indigo
        case .disableBuiltinMouse: return .orange
        case .disableTimeout: return .yellow
        case .playChain: return .orange
        case .bypass: return .green
        case .blockSleepSpamming: return .indigo
        case .sdkShift: return .blue
        case .useNativePlatform: return .mint
        case .checkMicPermissionSync: return .pink
        case .limitMotionUpdateFrequency: return .teal
        case .rootWorkDir: return .blue
        case .metalHUD: return .purple
        }
    }

    var keyPath: WritableKeyPath<AppSettingsData, Bool> {
        switch self {
        case .duoVerticalBar: return \.duoVerticalBar
        case .hideTitleBar: return \.hideTitleBar
        case .powerSavingMode: return \.powerSavingMode
        case .memorySavingMode: return \.memorySavingMode
        case .metalMemorySaver: return \.metalMemorySaver
        case .avMediaSaver: return \.avMediaSaver
        case .blockSplashAds: return \.blockSplashAds
        case .mockLocationEnabled: return \.mockLocationEnabled
        case .floatingWindow: return \.floatingWindow
        case .keymapping: return \.keymapping
        case .noKMOnInput: return \.noKMOnInput
        case .enableScrollWheel: return \.enableScrollWheel
        case .optionScrollZoom: return \.optionScrollZoom
        case .touchAlternatives: return \.touchAlternatives
        case .disableBuiltinMouse: return \.disableBuiltinMouse
        case .disableTimeout: return \.disableTimeout
        case .playChain: return \.playChain
        case .bypass: return \.bypass
        case .blockSleepSpamming: return \.blockSleepSpamming
        case .sdkShift: return \.sdkShift
        case .useNativePlatform: return \.useNativePlatform
        case .checkMicPermissionSync: return \.checkMicPermissionSync
        case .limitMotionUpdateFrequency: return \.limitMotionUpdateFrequency
        case .rootWorkDir: return \.rootWorkDir
        case .metalHUD: return \.metalHUD
        }
    }
}

struct FeatureManagerView: View {
    @EnvironmentObject var appsVM: AppsVM

    @State private var selectedItem: ManagedSettingItem?
    @State private var featureSearch = ""
    @State private var appSearch = ""
    @State private var settingsRevision = 0

    private var sortedApps: [PlayApp] {
        appsVM.apps.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    var body: some View {
        Group {
            switch selectedItem {
            case .toggle(let feature):
                FeatureToggleDetailView(
                    feature: feature,
                    apps: sortedApps,
                    searchText: $appSearch,
                    settingsRevision: settingsRevision,
                    onBack: clearSelection,
                    onToggleApp: { app, enabled in
                        setToggleFeature(feature, enabled: enabled, for: [app])
                    },
                    onSetAll: { targetApps, enabled in
                        setToggleFeature(feature, enabled: enabled, for: targetApps)
                    }
                )
            case .picker(let feature):
                FeaturePickerDetailView(
                    feature: feature,
                    apps: sortedApps,
                    searchText: $appSearch,
                    settingsRevision: settingsRevision,
                    onBack: clearSelection,
                    onSelectValue: { app, value in
                        setPickerFeature(feature, value: value, for: [app])
                    },
                    onSetAll: { targetApps, value in
                        setPickerFeature(feature, value: value, for: targetApps)
                    }
                )
            case .none:
                FeatureCategoryListView(
                    apps: sortedApps,
                    searchText: $featureSearch,
                    settingsRevision: settingsRevision,
                    onSelect: { item in
                        appSearch = ""
                        selectedItem = item
                    }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(selectedItem?.localizedTitle ?? NSLocalizedString("sidebar.featureManager", comment: ""))
        .onAppear {
            if !appsVM.hasLoadedOnce && !appsVM.updatingApps {
                appsVM.fetchApps()
            }
            settingsRevision += 1
        }
    }

    private func clearSelection() {
        appSearch = ""
        selectedItem = nil
    }

    private func setToggleFeature(_ feature: ManagedToggleFeature, enabled: Bool, for targetApps: [PlayApp]) {
        var changed = false
        for app in targetApps {
            var updated = app.settings.settings
            guard updated[keyPath: feature.keyPath] != enabled else { continue }
            updated[keyPath: feature.keyPath] = enabled
            if feature == .sdkShift && updated.resolution == 7 {
                app.settings.applySmartAdaptDefaults(to: &updated)
            }
            app.settings.settings = updated
            changed = true
        }
        if changed {
            settingsRevision += 1
        }
    }

    private func setPickerFeature(_ feature: ManagedPickerFeature, value: String, for targetApps: [PlayApp]) {
        var changed = false
        for app in targetApps {
            var updated = app.settings.settings
            if feature.apply(value: value, to: &updated, app: app) {
                app.settings.settings = updated
                changed = true
            }
        }
        if changed {
            settingsRevision += 1
        }
    }
}

private struct FeatureCategoryListView: View {
    let apps: [PlayApp]
    @Binding var searchText: String
    let settingsRevision: Int
    let onSelect: (ManagedSettingItem) -> Void

    private var filteredSections: [(section: ManagedFeatureSection, items: [ManagedSettingItem])] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ManagedFeatureSection.allCases.compactMap { section in
            let matches = section.items.filter { item in
                guard !query.isEmpty else { return true }
                return item.localizedTitle.lowercased().contains(query)
                    || item.localizedDescription.lowercased().contains(query)
                    || item.rawKey.lowercased().contains(query)
            }
            return matches.isEmpty ? nil : (section, matches)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("sidebar.featureManager")
                            .font(.title2.bold())
                        Text("featureManager.subtitle")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    FeatureSearchField(
                        placeholder: NSLocalizedString("featureManager.searchFeatures", comment: ""),
                        text: $searchText
                    )
                    .frame(width: 220)
                }

                ForEach(filteredSections, id: \.section.id) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(LocalizedStringKey(group.section.titleKey))
                            .font(.headline)
                            .foregroundColor(.secondary)
                            .padding(.leading, 4)

                        VStack(spacing: 0) {
                            ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                                FeatureCategoryRow(
                                    item: item,
                                    summaryText: summaryText(for: item),
                                    onTap: { onSelect(item) }
                                )
                                if index < group.items.count - 1 {
                                    Divider()
                                        .padding(.leading, 54)
                                }
                            }
                        }
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color(nsColor: .controlBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(.quaternary, lineWidth: 1)
                        )
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
    }

    private func summaryText(for item: ManagedSettingItem) -> String {
        _ = settingsRevision
        switch item {
        case .toggle(let feature):
            let enabled = apps.reduce(0) { $0 + ($1.settings.settings[keyPath: feature.keyPath] ? 1 : 0) }
            return "\(enabled) / \(apps.count)"
        case .picker(let feature):
            return pickerSummary(for: feature, apps: apps)
        }
    }
}

private func pickerSummary(for feature: ManagedPickerFeature, apps: [PlayApp]) -> String {
    guard !apps.isEmpty else { return "0" }
    let values = apps.map { feature.currentValue(in: $0.settings.settings) }
    if let first = values.first, values.allSatisfy({ $0 == first }) {
        return feature.displayLabel(for: first)
    }
    let customCount = values.filter { $0 != feature.defaultValue }.count
    return String(format: NSLocalizedString("featureManager.customCount", comment: ""), customCount)
}

private struct FeatureCategoryRow: View {
    let item: ManagedSettingItem
    let summaryText: String
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                FeatureIconBadge(symbolName: item.symbolName, color: item.badgeColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey(item.titleKey))
                        .font(.body)
                        .foregroundColor(.primary)
                    Text(LocalizedStringKey(item.descriptionKey))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                Text(summaryText)
                    .font(.subheadline.monospacedDigit())
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .background(isHovered ? Color.primary.opacity(0.05) : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

private struct FeatureToggleDetailView: View {
    let feature: ManagedToggleFeature
    let apps: [PlayApp]
    @Binding var searchText: String
    let settingsRevision: Int
    let onBack: () -> Void
    let onToggleApp: (PlayApp, Bool) -> Void
    let onSetAll: ([PlayApp], Bool) -> Void

    private var filteredApps: [PlayApp] {
        filterApps(apps, query: searchText)
    }

    private var enabledCount: Int {
        _ = settingsRevision
        return apps.reduce(0) { $0 + ($1.settings.settings[keyPath: feature.keyPath] ? 1 : 0) }
    }

    private var allVisibleEnabled: Bool {
        _ = settingsRevision
        return !filteredApps.isEmpty
            && filteredApps.allSatisfy { $0.settings.settings[keyPath: feature.keyPath] }
    }

    private var allVisibleDisabled: Bool {
        _ = settingsRevision
        return !filteredApps.isEmpty
            && filteredApps.allSatisfy { !$0.settings.settings[keyPath: feature.keyPath] }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                FeatureBackButton(action: onBack)
                FeatureIconBadge(symbolName: feature.symbolName, color: feature.badgeColor, size: 24)

                Text(LocalizedStringKey(feature.titleKey))
                    .font(.title3.bold())
                    .lineLimit(1)

                FeatureSummaryPill(text: "\(enabledCount) / \(apps.count)")

                Spacer(minLength: 8)

                FeatureSearchField(
                    placeholder: NSLocalizedString("featureManager.searchApps", comment: ""),
                    text: $searchText
                )
                .frame(width: 190)

                Button("featureManager.enableAll") {
                    onSetAll(filteredApps, true)
                }
                .buttonStyle(.bordered)
                .disabled(filteredApps.isEmpty || allVisibleEnabled)

                Button("featureManager.disableAll") {
                    onSetAll(filteredApps, false)
                }
                .buttonStyle(.bordered)
                .disabled(filteredApps.isEmpty || allVisibleDisabled)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider()

            FeatureDetailCardScroll(
                descriptionKey: feature.descriptionKey,
                isEmptyApps: apps.isEmpty,
                isEmptyFiltered: filteredApps.isEmpty
            ) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(filteredApps.enumerated()), id: \.element.url) { index, app in
                        FeatureToggleAppRow(
                            app: app,
                            isEnabled: isEnabled(for: app),
                            onToggle: { onToggleApp(app, $0) }
                        )
                        if index < filteredApps.count - 1 {
                            Divider()
                                .padding(.leading, 54)
                        }
                    }
                }
            }
        }
    }

    private func isEnabled(for app: PlayApp) -> Bool {
        _ = settingsRevision
        return app.settings.settings[keyPath: feature.keyPath]
    }
}

private struct FeaturePickerDetailView: View {
    let feature: ManagedPickerFeature
    let apps: [PlayApp]
    @Binding var searchText: String
    let settingsRevision: Int
    let onBack: () -> Void
    let onSelectValue: (PlayApp, String) -> Void
    let onSetAll: ([PlayApp], String) -> Void

    private var filteredApps: [PlayApp] {
        filterApps(apps, query: searchText)
    }

    private var summaryBadge: String {
        _ = settingsRevision
        return pickerSummary(for: feature, apps: apps)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                FeatureBackButton(action: onBack)
                FeatureIconBadge(symbolName: feature.symbolName, color: feature.badgeColor, size: 24)

                Text(LocalizedStringKey(feature.titleKey))
                    .font(.title3.bold())
                    .lineLimit(1)

                FeatureSummaryPill(text: summaryBadge)

                Spacer(minLength: 8)

                FeatureSearchField(
                    placeholder: NSLocalizedString("featureManager.searchApps", comment: ""),
                    text: $searchText
                )
                .frame(width: 190)

                Menu("featureManager.setAll") {
                    ForEach(feature.options) { option in
                        Button(option.displayText) {
                            onSetAll(filteredApps, option.id)
                        }
                    }
                }
                .fixedSize()
                .disabled(filteredApps.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider()

            FeatureDetailCardScroll(
                descriptionKey: feature.descriptionKey,
                isEmptyApps: apps.isEmpty,
                isEmptyFiltered: filteredApps.isEmpty
            ) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(filteredApps.enumerated()), id: \.element.url) { index, app in
                        FeaturePickerAppRow(
                            app: app,
                            feature: feature,
                            selectedValue: currentValue(for: app),
                            onSelect: { onSelectValue(app, $0) }
                        )
                        if index < filteredApps.count - 1 {
                            Divider()
                                .padding(.leading, 54)
                        }
                    }
                }
            }
        }
    }

    private func currentValue(for app: PlayApp) -> String {
        _ = settingsRevision
        return feature.currentValue(in: app.settings.settings)
    }
}

private func filterApps(_ apps: [PlayApp], query: String) -> [PlayApp] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !trimmed.isEmpty else { return apps }
    return apps.filter { app in
        app.name.lowercased().contains(trimmed)
            || app.searchText.contains(trimmed)
            || app.info.bundleIdentifier.lowercased().contains(trimmed)
    }
}

private struct FeatureDetailCardScroll<Content: View>: View {
    let descriptionKey: String
    let isEmptyApps: Bool
    let isEmptyFiltered: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(LocalizedStringKey(descriptionKey))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Divider()

                if isEmptyFiltered {
                    Text(isEmptyApps ? "featureManager.noApps" : "featureManager.noMatchingApps")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                } else {
                    content()
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.quaternary, lineWidth: 1)
            )
            .padding(20)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct FeatureToggleAppRow: View {
    let app: PlayApp
    let isEnabled: Bool
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(spacing: 12) {
            FeatureAppIconView(app: app)
            FeatureAppLabel(app: app)
            Spacer(minLength: 12)
            Toggle("", isOn: Binding(
                get: { isEnabled },
                set: { onToggle($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

private struct FeaturePickerAppRow: View {
    let app: PlayApp
    let feature: ManagedPickerFeature
    let selectedValue: String
    let onSelect: (String) -> Void

    var body: some View {
        HStack(spacing: 12) {
            FeatureAppIconView(app: app)
            FeatureAppLabel(app: app)
            Spacer(minLength: 12)
            Picker("", selection: Binding(
                get: { selectedValue },
                set: { onSelect($0) }
            )) {
                ForEach(feature.optionsIncludingCurrent(selectedValue)) { option in
                    Text(option.displayText).tag(option.id)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 185)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

private struct FeatureAppLabel: View {
    let app: PlayApp

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(app.name)
                .font(.body)
                .lineLimit(1)
            Text(app.info.bundleIdentifier)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
    }
}

private struct FeatureBackButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                Text("featureManager.back")
            }
        }
        .buttonStyle(.bordered)
    }
}

private struct FeatureSummaryPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline.monospacedDigit())
            .foregroundColor(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.secondary.opacity(0.14)))
    }
}

private struct FeatureAppIconView: View {
    let app: PlayApp
    @State private var appIconImage: NSImage?

    var body: some View {
        Group {
            if let image = appIconImage ?? Cacher.shared.cachedAppIcon(forPath: app.url.path) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.secondary.opacity(0.15))
            }
        }
        .frame(width: 28, height: 28)
        .cornerRadius(6)
        .task(id: app.url) {
            let path = app.url.path
            if appIconImage == nil {
                if let cached = Cacher.shared.cachedAppIcon(forPath: path) {
                    appIconImage = cached
                } else {
                    appIconImage = await Cacher.shared.loadAppIcon(forPath: path)
                }
            }
        }
    }
}

private struct FeatureIconBadge: View {
    let symbolName: String
    let color: Color
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(color)
            Image(systemName: symbolName)
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundColor(.white)
        }
        .frame(width: size, height: size)
    }
}

private struct FeatureSearchField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
                .font(.caption)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
    }
}
