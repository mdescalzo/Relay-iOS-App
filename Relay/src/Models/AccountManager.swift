//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

import Foundation
import PromiseKit
import StorageManager

/**
 * Signal is actually two services - textSecure for messages and red phone (for calls). 
 * AccountManager delegates to both.
 */
@objc
class AccountManager: NSObject {
    let TAG = "[AccountManager]"

    private static let LocalUIDKey = "AccountManagerLocalUIDKey"
    private static let LocalDeviceKey = "AccountManagerLocalDeviceKey"

    var pushManager: PushManager {
        // dependency injection hack since PushManager has *alot* of dependencies, and would induce a cycle.
        return PushManager.shared()
    }

    @objc
    override init() {

        super.init()
    }

    // MARK: registration

    @objc func register(verificationCode: String,
                        pin: String?) -> AnyPromise {
        return AnyPromise(register(verificationCode: verificationCode, pin: pin) as Promise<Void>)
    }

    func register(verificationCode: String,
                  pin: String?) -> Promise<Void> {
      }

    private func registerForTextSecure(verificationCode: String,
                                       pin: String?) -> Promise<Void> {
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
                                                                       success: { resolver.fulfill() },
                                                                       failure: { (error) in resolver.reject(error) })
        }
    }
}
