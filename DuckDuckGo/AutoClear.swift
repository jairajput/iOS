//
//  AutoClear.swift
//  DuckDuckGo
//
//  Copyright © 2019 DuckDuckGo. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

import Foundation
import UIKit

protocol AutoClearWorker {
    
    func clearNavigationStack()
    func forgetData() async
    func forgetTabs()
    func clearDataFinished(_: AutoClear)
}

class AutoClear {
    
    private let worker: AutoClearWorker
    private var timestamp: TimeInterval?
    
    private let appSettings: AppSettings

    var isClearingEnabled: Bool {
        return AutoClearSettingsModel(settings: appSettings) != nil
    }
    
    init(worker: AutoClearWorker, appSettings: AppSettings = AppDependencyProvider.shared.appSettings) {
        self.worker = worker
        self.appSettings = appSettings
    }
    
    @MainActor
    private func clearData() async {
        guard let settings = AutoClearSettingsModel(settings: appSettings) else { return }
        
        if settings.action.contains(.clearTabs) {
            worker.forgetTabs()
        }

        if settings.action.contains(.clearData) {
            await worker.forgetData()
        }

        worker.clearDataFinished(self)
    }
    
    /// Note: function is parametrised because of tests.
    func applicationDidEnterBackground(_ time: TimeInterval = Date().timeIntervalSince1970) {
        timestamp = time
    }
    
    private func shouldClearData(elapsedTime: TimeInterval) -> Bool {
        guard let settings = AutoClearSettingsModel(settings: appSettings) else { return false }
        
        switch settings.timing {
        case .termination:
            return false
        case .delay5min:
            return elapsedTime > 5 * 60
        case .delay15min:
            return elapsedTime > 15 * 60
        case .delay30min:
            return elapsedTime > 30 * 60
        case .delay60min:
            return elapsedTime > 60 * 60
        }
    }
    
    @MainActor
    func applicationWillMoveToForeground() async {
        guard isClearingEnabled,
            let timestamp = timestamp,
            shouldClearData(elapsedTime: Date().timeIntervalSince1970 - timestamp) else { return }
        
        self.timestamp = nil
        worker.clearNavigationStack()
        await clearData()
    }
}
