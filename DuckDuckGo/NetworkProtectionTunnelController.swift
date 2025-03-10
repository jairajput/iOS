//
//  NetworkProtectionTunnelController.swift
//  DuckDuckGo
//
//  Copyright © 2023 DuckDuckGo. All rights reserved.
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

#if NETWORK_PROTECTION

import Foundation
import Combine
import Core
import NetworkExtension
import NetworkProtection

final class NetworkProtectionTunnelController: TunnelController {
    static var shouldSimulateFailure: Bool = false

    private let debugFeatures = NetworkProtectionDebugFeatures()
    private let tokenStore = NetworkProtectionKeychainTokenStore()
    private let errorStore = NetworkProtectionTunnelErrorStore()
    private let notificationCenter: NotificationCenter = .default
    private var previousStatus: NEVPNStatus = .invalid
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Starting & Stopping the VPN

    enum StartError: LocalizedError, CustomNSError {
        case simulateControllerFailureError
        case loadFromPreferencesFailed(Error)
        case saveToPreferencesFailed(Error)
        case startVPNFailed(Error)
        case fetchAuthTokenFailed(Error)
        case configSystemPermissionsDenied(Error)

        public var errorCode: Int {
            switch self {
            case .simulateControllerFailureError: 0
            case .loadFromPreferencesFailed: 1
            case .saveToPreferencesFailed: 2
            case .startVPNFailed: 3
            case .fetchAuthTokenFailed: 4
            case .configSystemPermissionsDenied: 5
            }
        }

        public var errorUserInfo: [String: Any] {
            switch self {
            case
                    .simulateControllerFailureError:
                return [:]
            case
                    .loadFromPreferencesFailed(let error),
                    .saveToPreferencesFailed(let error),
                    .startVPNFailed(let error),
                    .fetchAuthTokenFailed(let error),
                    .configSystemPermissionsDenied(let error):
                return [NSUnderlyingErrorKey: error]
            }
        }
    }

    init() {
        subscribeToStatusChanges()
    }

    /// Starts the VPN connection used for Network Protection
    ///
    func start() async {
        Pixel.fire(pixel: .networkProtectionControllerStartAttempt)

        do {
            try await startWithError()
            Pixel.fire(pixel: .networkProtectionControllerStartSuccess)
        } catch {
            if case StartError.configSystemPermissionsDenied = error {
                return
            }
            Pixel.fire(pixel: .networkProtectionControllerStartFailure, error: error)

            #if DEBUG
            errorStore.lastErrorMessage = error.localizedDescription
            #endif
        }
    }

    func stop() async {
        guard let tunnelManager = await loadTunnelManager() else {
            return
        }

        do {
            try await disableOnDemand(tunnelManager: tunnelManager)
        } catch {
            #if DEBUG
            errorStore.lastErrorMessage = error.localizedDescription
            #endif
        }

        tunnelManager.connection.stopVPNTunnel()
    }

    func removeVPN() async {
        try? await tunnelManager?.removeFromPreferences()
    }

    // MARK: - Connection Status Querying

    var isInstalled: Bool {
        get async {
            let tunnelManager = await loadTunnelManager()
            return tunnelManager != nil
        }
    }

    /// Queries Network Protection to know if its VPN is connected.
    ///
    /// - Returns: `true` if the VPN is connected, connecting or reasserting, and `false` otherwise.
    ///
    var isConnected: Bool {
        get async {
            guard let tunnelManager = await loadTunnelManager() else {
                return false
            }

            switch tunnelManager.connection.status {
            case .connected, .connecting, .reasserting:
                return true
            default:
                return false
            }
        }
    }

    private func startWithError() async throws {
        let tunnelManager: NETunnelProviderManager

        do {
            tunnelManager = try await loadOrMakeTunnelManager()
        } catch {
            throw error
        }

        switch tunnelManager.connection.status {
        case .invalid:
            reloadTunnelManager()
            try await startWithError()
        case .connected:
            // Intentional no-op
            break
        default:
            try start(tunnelManager)
        }
    }

    /// Reloads the tunnel manager from preferences.
    ///
    private func reloadTunnelManager() {
        internalTunnelManager = nil
    }

    private func start(_ tunnelManager: NETunnelProviderManager) throws {
        var options = [String: NSObject]()

        if Self.shouldSimulateFailure {
            Self.shouldSimulateFailure = false
            throw StartError.simulateControllerFailureError
        }

        options["activationAttemptId"] = UUID().uuidString as NSString
        do {
            options["authToken"] = try tokenStore.fetchToken() as NSString?
        } catch {
            throw StartError.fetchAuthTokenFailed(error)
        }
        options[NetworkProtectionOptionKey.selectedEnvironment] = VPNSettings(defaults: .networkProtectionGroupDefaults)
            .selectedEnvironment.rawValue as NSString

        do {
            try tunnelManager.connection.startVPNTunnel(options: options)
            UniquePixel.fire(pixel: .networkProtectionNewUser) { error in
                guard error != nil else { return }
                UserDefaults.networkProtectionGroupDefaults.vpnFirstEnabled = Pixel.Event.networkProtectionNewUser.lastFireDate(
                    uniquePixelStorage: UniquePixel.storage
                )
            }
        } catch {
            Pixel.fire(pixel: .networkProtectionActivationRequestFailed, error: error)
            throw StartError.startVPNFailed(error)
        }
    }

    /// The actual storage for our tunnel manager.
    ///
    private var internalTunnelManager: NETunnelProviderManager?

    /// The tunnel manager: will try to load if it its not loaded yet, but if one can't be loaded from preferences,
    /// a new one will not be created.  This is useful for querying the connection state and information without triggering
    /// a VPN-access popup to the user.
    ///
    private var tunnelManager: NETunnelProviderManager? {
        get async {
            guard let tunnelManager = internalTunnelManager else {
                let tunnelManager = await loadTunnelManager()
                internalTunnelManager = tunnelManager
                return tunnelManager
            }

            return tunnelManager
        }
    }

    private func loadTunnelManager() async -> NETunnelProviderManager? {
        try? await NETunnelProviderManager.loadAllFromPreferences().first
    }

    private func loadOrMakeTunnelManager() async throws -> NETunnelProviderManager {
        guard let tunnelManager = await tunnelManager else {
            let tunnelManager = NETunnelProviderManager()
            try await setupAndSave(tunnelManager)
            internalTunnelManager = tunnelManager
            return tunnelManager
        }

        try await setupAndSave(tunnelManager)
        return tunnelManager
    }

    private func setupAndSave(_ tunnelManager: NETunnelProviderManager) async throws {
        setup(tunnelManager)
        try await saveToPreferences(tunnelManager)
        try await loadFromPreferences(tunnelManager)
        try await saveToPreferences(tunnelManager)
    }

    private func saveToPreferences(_ tunnelManager: NETunnelProviderManager) async throws {
        do {
            try await tunnelManager.saveToPreferences()
        } catch {
            let nsError = error as NSError
            if nsError.code == NEVPNError.Code.configurationReadWriteFailed.rawValue,
               nsError.localizedDescription == "permission denied" {
                // This is a user denying the system permissions prompt to add the config
                // Maybe we should fire another pixel here, but not a start failure as this is an imaginable scenario
                // The code could be caused by a number of problems so I'm using the localizedDescription to catch that case
                throw StartError.configSystemPermissionsDenied(error)
            }
            throw StartError.saveToPreferencesFailed(error)
        }
    }

    private func loadFromPreferences(_ tunnelManager: NETunnelProviderManager) async throws {
        do {
            try await tunnelManager.loadFromPreferences()
        } catch {
            throw StartError.loadFromPreferencesFailed(error)
        }
    }

    /// Setups the tunnel manager if it's not set up already.
    ///
    private func setup(_ tunnelManager: NETunnelProviderManager) {
        tunnelManager.localizedDescription = "DuckDuckGo VPN"
        tunnelManager.isEnabled = true

        tunnelManager.protocolConfiguration = {
            let protocolConfiguration = NETunnelProviderProtocol()
            protocolConfiguration.serverAddress = "127.0.0.1" // Dummy address... the NetP service will take care of grabbing a real server

            // always-on
            protocolConfiguration.disconnectOnSleep = false

            return protocolConfiguration
        }()

        // reconnect on reboot
        tunnelManager.onDemandRules = [NEOnDemandRuleConnect()]
    }

    // MARK: - Observing Status Changes

    private func subscribeToStatusChanges() {
        notificationCenter.publisher(for: .NEVPNStatusDidChange)
            .sink(receiveValue: handleStatusChange(_:))
            .store(in: &cancellables)
    }

    private func handleStatusChange(_ notification: Notification) {
        guard !debugFeatures.alwaysOnDisabled,
              let session = (notification.object as? NETunnelProviderSession),
              session.status != previousStatus,
              let manager = session.manager as? NETunnelProviderManager else {
            return
        }

        Task { @MainActor in
            previousStatus = session.status

            switch session.status {
            case .connected:
                try await enableOnDemand(tunnelManager: manager)
            default:
                break
            }

        }
    }

    // MARK: - On Demand

    @MainActor
    func enableOnDemand(tunnelManager: NETunnelProviderManager) async throws {
        let rule = NEOnDemandRuleConnect()
        rule.interfaceTypeMatch = .any

        tunnelManager.onDemandRules = [rule]
        tunnelManager.isOnDemandEnabled = true

        try await tunnelManager.saveToPreferences()
    }

    @MainActor
    func disableOnDemand(tunnelManager: NETunnelProviderManager) async throws {
        tunnelManager.isOnDemandEnabled = false

        try await tunnelManager.saveToPreferences()
    }
}

#endif
