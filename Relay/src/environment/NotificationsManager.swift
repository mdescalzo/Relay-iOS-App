//
//  NotificationsManager.swift
//  Relay
//
//  Created by Mark Descalzo on 2/26/19.
//  Copyright © 2019 Forsta Labs, Inc. All rights reserved.
//

import RelayServiceKit
import AudioToolbox
import YapDatabase
import RelayMessaging


@objc
class NotificationsManager: NSObject, NotificationsProtocol, OWSCallNotificationsAdaptee {
    
    private var currentNotifications = [String : UILocalNotification]()
    private lazy var prefs = Environment.current()?.preferences
    private lazy var notificationPreviewType = self.prefs?.notificationPreviewType()
    private var notificationHistory = [Date]()
    var audioPlayer: OWSAudioPlayer?
    
    override init() {
        super.init()
        SwiftSingletons.register(self)
    }
    
    // MARK: - Message notifications
    func notifyUser(for incomingMessage: TSIncomingMessage, in thread: TSThread, contactsManager: ContactsManagerProtocol, transaction: YapDatabaseReadTransaction) {
        // While batch processing, some of the necessary changes have not been commited.
        let rawMessageText = incomingMessage.previewText(with: transaction)
        
        // iOS strips anything that looks like a printf formatting character from
        // the notification body, so if we want to dispay a literal "%" in a notification
        // it must be escaped.
        // see https://developer.apple.com/documentation/uikit/uilocalnotification/1616646-alertbody
        // for more details.
        let messageText = DisplayableText.filterNotificationText(rawMessageText)

        DispatchMainThreadSafe {
            guard !thread.isMuted else {
                return
            }
            
            let shouldPlaySound = self.shouldPlaySoundForNotification()
            let senderName = contactsManager.displayName(forRecipientId: incomingMessage.authorId)
            
            if UIApplication.shared.applicationState != .active && messageText != nil {
                let notification = UILocalNotification()
                if shouldPlaySound {
                    let sound = OWSSounds.notificationSound(for: thread)
                    notification.soundName = OWSSounds.filename(for: sound)
                }
                switch self.notificationPreviewType {
                case .namePreview?:
                    do {
                        // Don't reply from lockscreen if anyone in this conversation is
                        // "no longer verified".
                        var isNoLongerVerified = false
                        for recipientId in thread.participantIds {
                            if OWSIdentityManager.shared().verificationState(forRecipientId: recipientId, transaction: transaction) == .noLongerVerified {
                                isNoLongerVerified = true
                                break
                            }
                        }
                        notification.category = (isNoLongerVerified ? Signal_Full_New_Message_Category_No_Longer_Verified :Signal_Full_New_Message_Category )
                        notification.userInfo = [ Signal_Thread_UserInfo_Key : thread.uniqueId,
                                                  Signal_Message_UserInfo_Key : incomingMessage.uniqueId ]
                        if senderName == thread.displayName() {
                            notification.alertBody = "\(senderName): \(messageText)"
                        } else {
                            notification.alertBody = String(format: NSLocalizedString("APN_MESSAGE_IN_GROUP_DETAILED", comment: ""), senderName!, thread.displayName(), messageText!)
                        }
                    }
                case .nameNoPreview?:
                    do {
                        notification.userInfo = [ Signal_Thread_UserInfo_Key : thread.uniqueId ]
                        notification.alertBody = String(format: NSLocalizedString("APN_MESSAGE_FROM", comment: ""), senderName!)
                    }
                default:
                    do {
                        Logger.warn("unknown notification preview type: \(self.notificationPreviewType)")
                        notification.alertBody = NSLocalizedString("APN_Message", comment: "")
                    }
                }
                PushManager.shared().present(notification, checkForCancel: true)
            } else {
                if shouldPlaySound && ((self.prefs?.soundInForeground())!) {
                    let sound = OWSSounds.notificationSound(for: thread)
                    let soundId = OWSSounds.systemSoundID(for: sound, quiet: true)
                    AudioServicesPlayAlertSound(soundId)
                }
            }
        }
    }
    
    func notifyUser(for error: TSErrorMessage, thread: TSThread, transaction: YapDatabaseReadWriteTransaction) {
        let messageText = error.previewText(with: transaction)
        
        transaction.addCompletionQueue(nil) {
            guard !thread.isMuted else {
                return
            }
            let shouldPlaySound = self.shouldPlaySoundForNotification()
            
            if UIApplication.shared.applicationState != .active && messageText.count > 0 {
                let notification = UILocalNotification()
                notification.userInfo = [ Signal_Thread_UserInfo_Key : thread.uniqueId ]
                if shouldPlaySound {
                    let sound = OWSSounds.notificationSound(for: thread)
                    notification.soundName = OWSSounds.filename(for: sound)
                }
                var alertBodyString: String
                let threadName = thread.displayName()
                switch self.notificationPreviewType {
                case .namePreview?, .nameNoPreview?:
                    do {
                        if threadName.count > 0 {
                            alertBodyString = "\(threadName): \(messageText)"
                        } else {
                            alertBodyString = messageText
                        }
                    }
                case .noNameNoPreview?:
                    do {
                        alertBodyString = messageText
                    }
                default:
                    do {
                        alertBodyString = messageText
                    }
                }
                notification.alertBody = alertBodyString
                PushManager.shared().present(notification, checkForCancel: false)
            } else {
                if shouldPlaySound && ((self.prefs?.soundInForeground())!) {
                    let sound = OWSSounds.notificationSound(for: thread)
                    let soundId = OWSSounds.systemSoundID(for: sound, quiet: true)
                    AudioServicesPlayAlertSound(soundId)
                }
            }
        }
    }
    
    func notifyUser(forThreadlessErrorMessage error: TSErrorMessage, transaction: YapDatabaseReadWriteTransaction) {
        
        let messageText = error.previewText(with: transaction)
        
        transaction.addCompletionQueue(nil) {
            let shouldPlaySound = self.shouldPlaySoundForNotification()
            
            if UIApplication.shared.applicationState != .active && messageText.count > 0 {
                let notification = UILocalNotification()
                if shouldPlaySound {
                    let sound = OWSSounds.globalNotificationSound()
                    notification.soundName = OWSSounds.filename(for: sound)
                }
                notification.alertBody = messageText
                PushManager.shared().present(notification, checkForCancel: false)
            } else {
                if shouldPlaySound && ((self.prefs?.soundInForeground())!) {
                    let sound = OWSSounds.globalNotificationSound()
                    let soundId = OWSSounds.systemSoundID(for: sound, quiet: true)
                    AudioServicesPlayAlertSound(soundId)
                }
            }
        }
    }
    
    // MARK: - Call notifications
    
    func presentIncomingCall(_ call: ConferenceCall, callerName: String) {
        Logger.debug("\(self.logTag) incoming call from: \(call.callId)")
        
        let notification = UILocalNotification()
        notification.category = PushManagerCategoriesIncomingCall
        // Rather than using notification sounds, we control the ringtone and repeat vibrations with the CallAudioManager.
        notification.soundName = OWSSounds.filename(for: .defaultiOSIncomingRingtone)
        let localCallId = call.callId
        notification.userInfo = [ PushManagerUserInfoKeysLocalCallId: localCallId ]
        
        var alertMessage: String
        
        switch notificationPreviewType {
        case .noNameNoPreview?:
            do {
                alertMessage = NSLocalizedString("INCOMING_CALL", comment: "notification body")
            }
        case .nameNoPreview?:
            do {
                alertMessage = String(format: NSLocalizedString("INCOMING_CALL_FROM", comment: "notification body"), callerName)
            }
        default:
            do {
                alertMessage = NSLocalizedString("INCOMING_CALL", comment: "notification body")
            }
        }
        notification.alertBody = "☎️ \(alertMessage)"
        
        present(notification, identifier: localCallId)
    }
    
    func presentMissedCall(_ call: ConferenceCall, callerName: String) {
        let thread = call.thread
        
        let notification = UILocalNotification()
        notification.category = PushManagerCategoriesMissedCall
        let localCallId = call.localUUID.uuidString
        notification.userInfo = [
            PushManagerUserInfoKeysLocalCallId: localCallId,
            PushManagerUserInfoKeysCallBackSignalRecipientId: call.callId,
            Signal_Thread_UserInfo_Key: thread.uniqueId
        ]
        
        if shouldPlaySoundForNotification() {
            let sound: OWSSound = OWSSounds.notificationSound(for: thread)
            notification.soundName = OWSSounds.filename(for: sound)
        }
        
        var alertMessage = ""
        switch notificationPreviewType {
        case .noNameNoPreview?:
            do {
                alertMessage = CallStrings.missedCallNotificationBodyWithoutCallerName
            }
        case .nameNoPreview?, .namePreview?:
            do {
                alertMessage = String(format: CallStrings.missedCallNotificationBodyWithCallerName, callerName)
            }
        default:
            do { /* do nothing */ }
        }
        notification.alertBody = "☎️ \(alertMessage)"
        
        present(notification, identifier: localCallId)
    }
    
    func presentMissedCallBecauseOfNewIdentity(call: ConferenceCall, callerName: String) {
        let thread = call.thread
        
        let notification = UILocalNotification()
        // Use category which allows call back
        notification.category = PushManagerCategoriesMissedCall
        let localCallId = call.localUUID.uuidString
        notification.userInfo = [
            PushManagerUserInfoKeysLocalCallId: localCallId,
            PushManagerUserInfoKeysCallBackSignalRecipientId: call.callId,
            Signal_Thread_UserInfo_Key: thread.uniqueId
        ]
        if shouldPlaySoundForNotification() {
            var sound: OWSSound = OWSSounds.notificationSound(for: thread)
            notification.soundName = OWSSounds.filename(for: sound)
        }
        
        var alertMessage = ""
        switch notificationPreviewType {
        case .noNameNoPreview?:
            do {
                alertMessage = CallStrings.missedCallWithIdentityChangeNotificationBodyWithoutCallerName
            }
        case .nameNoPreview?, .namePreview?:
            do {
                alertMessage = String(format: CallStrings.missedCallWithIdentityChangeNotificationBodyWithCallerName, callerName)
            }
        default:
            do { /* do nothing */ }
        }
        notification.alertBody = "☎️ \(alertMessage)"
        
        present(notification, identifier: localCallId)
    }
    
    func presentMissedCallBecauseOfNoLongerVerifiedIdentity(call: ConferenceCall, callerName: String) {
        let thread = call.thread
        let notification = UILocalNotification()
        // Use category which does not allow call back
        notification.category = PushManagerCategoriesMissedCallFromNoLongerVerifiedIdentity
        let localCallId = call.localUUID.uuidString
        notification.userInfo = [
            PushManagerUserInfoKeysLocalCallId: localCallId,
            PushManagerUserInfoKeysCallBackSignalRecipientId: call.callId,
            Signal_Thread_UserInfo_Key: thread.uniqueId
        ]
        if shouldPlaySoundForNotification() {
            var sound: OWSSound = OWSSounds.notificationSound(for: thread)
            notification.soundName = OWSSounds.filename(for: sound)
        }
        
        var alertMessage = ""
        switch notificationPreviewType {
        case .noNameNoPreview?:
            alertMessage = CallStrings.missedCallWithIdentityChangeNotificationBodyWithoutCallerName
        case .nameNoPreview?, .namePreview?:
            alertMessage = String(format: CallStrings.missedCallWithIdentityChangeNotificationBodyWithCallerName, callerName)
        default:
            do { /* do nothing */ }
        }
        notification.alertBody = "☎️ \(alertMessage)"
        
        present(notification, identifier: localCallId)
        
    }
    
    // MARK: - Utility
    
    @objc
    public func clearAllNotifications() {
        self.currentNotifications.removeAll()
    }
    
    @objc
    public class func presentDebugNotification() {
        let notification = UILocalNotification()
        notification.category = Signal_Full_New_Message_Category;
        notification.soundName = OWSSounds.filename(for: .defaultiOSIncomingRingtone)
        notification.alertBody = "test";
        UIApplication.shared.scheduleLocalNotification(notification)
    }
    
    private func shouldPlaySoundForNotification() -> Bool {
        let lockQueue = DispatchQueue(label: "\(self.logTag)")
        var returnVal: Bool = false
        lockQueue.sync {
            // Play no more than 2 notification sounds in a given
            // five-second window.
            let kNotificationWindowSeconds: CGFloat = 5.0
            let kMaxNotificationRate: Int = 2
            
            // Cull obsolete notification timestamps from the thread's notification history.
            while notificationHistory.count > 0 {
                let notificationTimestamp: Date? = notificationHistory[0]
                let notificationAgeSeconds = CGFloat(fabs(Float(notificationTimestamp?.timeIntervalSinceNow ?? 0.0)))
                if notificationAgeSeconds > kNotificationWindowSeconds {
                    notificationHistory.remove(at: 0)
                } else {
                    break
                }
            }
            
            // Ignore notifications if necessary.
            let shouldPlaySound: Bool = notificationHistory.count < kMaxNotificationRate
            
            if shouldPlaySound {
                // Add new notification timestamp to the thread's notification history.
                let newNotificationTimestamp = Date()
                notificationHistory.append(newNotificationTimestamp)
                
                returnVal = true
            } else {
                Logger.debug("Skipping sound for notification")
                returnVal = false
            }
        }
        return returnVal
    }
    
    private func present(_ notification: UILocalNotification, identifier: String) {
        if notification.alertBody != nil {
            notification.alertBody = notification.alertBody!.filterStringForDisplay()
        }
        
        DispatchMainThreadSafe({
            if UIApplication.shared.applicationState == .active {
                Logger.debug("\(self.logTag) skipping notification; app is in foreground and active.")
                return
            }
            // Replace any existing notification
            // e.g. when an "Incoming Call" notification gets replaced with a "Missed Call" notification.
            if self.currentNotifications[identifier] != nil {
                self.cancelNotification(withIdentifier: identifier)
            }
            UIApplication.shared.scheduleLocalNotification(notification)
            Logger.debug("\(self.logTag) presenting notification with identifier: \(identifier)")
            
            self.currentNotifications[identifier] = notification
        })
    }
    
    private func cancelNotification(withIdentifier identifier: String) {
        DispatchMainThreadSafe({
            guard let notification: UILocalNotification = self.currentNotifications[identifier] else {
                Logger.warn("\(self.logTag) Couldn't cancel notification because none was found with identifier: \(identifier)")
                return
            }
            self.currentNotifications.removeValue(forKey: identifier)
            UIApplication.shared.cancelLocalNotification(notification)
        })
    }
    
    
}
