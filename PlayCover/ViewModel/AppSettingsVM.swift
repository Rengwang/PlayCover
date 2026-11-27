//
//  AppSettingsVM.swift
//  PlayCover
//
//  Created by 이승윤 on 2022/08/15.
//

import Combine
import Foundation

class AppSettingsVM: ObservableObject {
    let app: PlayApp
    @Published var settings: AppSettings
    private var settingsCancellable: AnyCancellable?

    init(app: PlayApp) {
        self.app = app
        settings = app.settings
        settingsCancellable = app.settings.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }
}
