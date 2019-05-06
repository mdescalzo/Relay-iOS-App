//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//


import RelayStorage
import SignalCoreKit

@objc
public class NoopNotificationsManager: NSObject, NotificationsProtocol {
    public func clearAllNotifications() {
        owsFailDebug("\(self.logTag) in \(#function).")
    }

    public func notifyUser(for incomingMessage: FLIMessage, in thread: FLIThread, contactsManager: ContactsManagerProtocol) {
        owsFailDebug("\(self.logTag) in \(#function).")
    }

    public func notifyUser(for error: FLIMessage, thread: FLIThread) {
        Logger.warn("\(self.logTag) in \(#function), skipping notification for: \(error.description)")
    }

    public func notifyUser(forThreadlessErrorMessage error: FLIMessage) {
        Logger.warn("\(self.logTag) in \(#function), skipping notification for: \(error.description)")
    }
}
