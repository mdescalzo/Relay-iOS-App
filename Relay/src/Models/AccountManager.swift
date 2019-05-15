//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

import Foundation
import PromiseKit
import RelayServiceKit

extension String: Error {}


/**
 * Signal is actually two services - textSecure for messages and red phone (for calls). 
 * AccountManager delegates to both.
 */
@objc
public class AccountManager: NSObject {
    let TAG = "[AccountManager]"

    let textSecureAccountManager: TSAccountManager
    let networkManager: TSNetworkManager
    let preferences: OWSPreferences

    var pushManager: PushManager {
        // dependency injection hack since PushManager has *alot* of dependencies, and would induce a cycle.
        return PushManager.shared()
    }

    @objc
    public required init(textSecureAccountManager: TSAccountManager, preferences: OWSPreferences) {
        self.networkManager = textSecureAccountManager.networkManager
        self.textSecureAccountManager = textSecureAccountManager
        self.preferences = preferences

        super.init()

        SwiftSingletons.register(self)
    }

    // MARK: registration

    @objc func register(verificationCode: String,
                        pin: String?) -> AnyPromise {
        return AnyPromise(register(verificationCode: verificationCode, pin: pin) as Promise<Void>)
    }

    func register(verificationCode: String,
                  pin: String?) -> Promise<Void> {
        guard verificationCode.count > 0 else {
            let error = OWSErrorWithCodeDescription(.userError,
                                                    NSLocalizedString("REGISTRATION_ERROR_BLANK_VERIFICATION_CODE",
                                                                      comment: "alert body during registration"))
            return Promise(error: error)
        }

        Logger.debug("\(self.TAG) registering with signal server")
        let registrationPromise: Promise<Void> = firstly {
            return self.registerForTextSecure(verificationCode: verificationCode, pin: pin)
        }.then {
            return self.syncPushTokens()
        }.recover { (error) -> Promise<Void> in
            switch error {
            case PushRegistrationError.pushNotSupported(let description):
                // This can happen with:
                // - simulators, none of which support receiving push notifications
                // - on iOS11 devices which have disabled "Allow Notifications" and disabled "Enable Background Refresh" in the system settings.
                Logger.info("\(self.TAG) Recovered push registration error. Registering for manual message fetcher because push not supported: \(description)")
                return self.enableManualMessageFetching()
            default:
                throw error
            }
        }.done {
            self.completeRegistration()
        }

        registrationPromise.retainUntilComplete()

        return registrationPromise
    }

    private func registerForTextSecure(verificationCode: String,
                                       pin: String?) -> Promise<Void> {
        return Promise { resolver in
            self.textSecureAccountManager.verifyAccount(withCode: verificationCode,
                                                        pin: pin,
                                                        success: {
                                                            resolver.fulfill(())
            },
                                                        failure: { (error) in
                                                            resolver.reject(error)
            })
        }
    }

    private func syncPushTokens() -> Promise<Void> {
        Logger.info("\(self.TAG) in \(#function)")
        let job = SyncPushTokensJob(accountManager: self, preferences: self.preferences)
        job.uploadOnlyIfStale = false
        return job.run()
    }

    private func completeRegistration() {
        Logger.info("\(self.TAG) in \(#function)")
        self.textSecureAccountManager.finalizeRegistration()
    }

    // MARK: Message Delivery

    func updatePushTokens(pushToken: String, voipToken: String) -> Promise<Void> {
        return Promise { resolver in
            self.textSecureAccountManager.registerForPushNotifications(pushToken: pushToken,
                                                                       voipToken: voipToken,
                                                                       success: { resolver.fulfill(()) },
                                                                       failure: { (error) in resolver.reject(error) })
        }
    }

    func enableManualMessageFetching() -> Promise<Void> {
        let anyPromise = textSecureAccountManager.setIsManualMessageFetchEnabled(true)
        return Promise(anyPromise).asVoid()
    }

    // MARK: Turn Server
    
    func getTurnServerInfo() -> Promise<[TurnServerInfo]> {
        return Promise { resolver in
            guard let urlBase = Bundle.main.object(forInfoDictionaryKey: "CCSM_Home_URL") as? String else {
                return resolver.reject("internal, can't get url base for atlas")
            }
            CCSMCommManager.getThings(urlBase+"/v1/rtc/servers", success: { things in
                var infos = [TurnServerInfo]()
                for thing in things ?? [] {
                    if let dict = thing as? [String: AnyObject] {
                        if let turnServerInfo = TurnServerInfo(attributes: dict) {
                            infos.append(turnServerInfo)
                        }
                    }
                }
                return resolver.fulfill(infos)
            }, failure:{ error in
                return resolver.reject(error ?? "internal error in getTurnServerInfo")
            })
        }
    }
}
