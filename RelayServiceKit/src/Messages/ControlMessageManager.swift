//
//  ControlMessageManager.swift
//  Forsta
//
//  Created by Mark Descalzo on 6/22/18.
//  Copyright © 2018 Forsta. All rights reserved.
//

import Foundation

@objc
class ControlMessageManager : NSObject
{
    @objc static func processIncomingControlMessage(message: IncomingControlMessage, transaction: YapDatabaseReadWriteTransaction)
    {
        Logger.debug("Received control message type: \(message.controlMessageType)")
        switch message.controlMessageType {
        case FLControlMessageSyncRequestKey:
            self.handleMessageSyncRequest(message: message, transaction: transaction)
        case FLControlMessageProvisionRequestKey:
            self.handleProvisionRequest(message: message, transaction: transaction)
        case FLControlMessageThreadUpdateKey:
            self.handleThreadUpdate(message: message, transaction: transaction)
        case FLControlMessageThreadClearKey:
            self.handleThreadClear(message: message, transaction: transaction)
        case FLControlMessageThreadCloseKey:
            self.handleThreadClose(message: message, transaction: transaction)
        case FLControlMessageThreadArchiveKey:
            self.handleThreadArchive(message: message, transaction: transaction)
        case FLControlMessageThreadRestoreKey:
            self.handleThreadRestore(message: message, transaction: transaction)
        case FLControlMessageThreadDeleteKey:
            self.handleThreadDelete(message: message, transaction: transaction)
        case FLControlMessageThreadSnoozeKey:
            self.handleThreadSnooze(message: message, transaction: transaction)
        case FLControlMessageCallJoinKey:
            self.handleCallJoin(message: message, transaction: transaction)
        case FLControlMessageCallOfferKey:
            self.handleCallOffer(message: message, transaction: transaction)
        case FLControlMessageCallAcceptOfferKey:
            self.handleCallAcceptOffer(message: message, transaction: transaction)
        case FLControlMessageCallLeaveKey:
            self.handleCallLeave(message: message, transaction: transaction)
        case FLControlMessageCallICECandidatesKey:
            self.handleCallICECandidates(message: message, transaction: transaction)
        case FLControlMessageMessageReadKey:
            self.handleMessageReadMark(message: message, transaction: transaction)
        default:
            Logger.info("Unhandled control message of type: \(message.controlMessageType)")
        }
    }
    
    static private func handleMessageReadMark(message: IncomingControlMessage, transaction: YapDatabaseReadWriteTransaction)
    {
        Logger.info("Received readMark message.")
        
        guard let dataBlob = message.forstaPayload["data"] as? NSDictionary else {
            Logger.debug("Received readMark message with no data blob.")
            return
        }

        guard let threadId = message.forstaPayload[FLThreadIDKey] as? String else {
            Logger.debug("Received readMark message with no threadId.")
            return
        }
        guard let senderId = (message.forstaPayload["sender"] as! NSDictionary).object(forKey: "userId") as? String else {
            Logger.debug("Received readMark message with no senderId.")
            return
        }
        var readTimestamp: UInt64 = NSDate.ows_millisecondTimeStamp()
        if (dataBlob.object(forKey: "readMark") != nil) {
            readTimestamp = dataBlob.object(forKey: "readMark") as! UInt64
        } else {
            Logger.warn("Received readMark control message without a readMark timestamp.")
        }
        
        if let thread = TSThread.fetch(uniqueId: threadId, transaction: transaction) {
            OWSReadReceiptManager.shared().markAsRead(byRecipientId: senderId,
                                                      beforeTimestamp: readTimestamp,
                                                      thread: thread,
                                                      wasLocal: false,
                                                      transaction: transaction)
        }
    }

    static private func handleCallICECandidates(message: IncomingControlMessage, transaction: YapDatabaseReadWriteTransaction)
    {
        guard let dataBlob = message.forstaPayload["data"] as? NSDictionary,
            let thread = TSThread.getOrCreateThread(withPayload: message.forstaPayload , transaction: transaction),
            let version = dataBlob.object(forKey: "version") as? Int64,
            let callId = dataBlob.object(forKey: "callId") as? String,
            let _ = dataBlob.object(forKey: "peerId") as? String,
            let iceCandidates: [NSDictionary] = dataBlob.object(forKey: "icecandidates") as? [NSDictionary],
            version == ConferenceCallProtocolLevel else {
                Logger.debug("Received callICECandidates missing requirements.")
                return
        }
        
        DispatchMainThreadSafe {
            TextSecureKitEnv.shared().callMessageHandler.receivedIceCandidates(with: thread,
                                                                               senderId: message.authorId,
                                                                               senderDeviceId: message.sourceDeviceId,
                                                                               callId: callId,
                                                                               iceCandidates: iceCandidates);
        }
    }
    
    static private func handleCallJoin(message: IncomingControlMessage, transaction: YapDatabaseReadWriteTransaction)
    {
        guard #available(iOS 10.0, *) else {
            Logger.debug("Ignoring callJoin due to iOS version.")
            return
        }

        // let sendTime = Date(timeIntervalSince1970: TimeInterval(message.timestamp) / 1000)
        // let age = Date().timeIntervalSince(sendTime)
        let age = TimeInterval(Double(message.serverAge?.uint64Value ?? 0) / 1000.0)
        if age > ConferenceCallStaleJoinTimeout {
            Logger.info("Ignoring stale callJoin message (>\(ConferenceCallStaleJoinTimeout) seconds old).")
            return
        }

        let forstaPayload = message.forstaPayload as NSDictionary
        guard let dataBlob = forstaPayload.object(forKey: "data") as? NSDictionary,
            let thread = TSThread.getOrCreateThread(withPayload: message.forstaPayload , transaction: transaction),
            let version = dataBlob.object(forKey: "version") as? Int64,
            let callId = dataBlob.object(forKey: "callId") as? String,
            let _ = dataBlob.object(forKey: "members") as? [String],
            let originator = dataBlob.object(forKey: "originator") as? String,
            version == ConferenceCallProtocolLevel else {
                Logger.debug("Received callJoin missing requirements.")
                return
        }

        DispatchMainThreadSafe {
            TextSecureKitEnv.shared().callMessageHandler.receivedJoin(with: thread,
                                                                      senderId: message.authorId,
                                                                      senderDeviceId: message.sourceDeviceId,
                                                                      originatorId: originator,
                                                                      callId: callId)
        }
    }
    
    static private func handleCallOffer(message: IncomingControlMessage, transaction: YapDatabaseReadWriteTransaction)
    {
        guard let dataBlob = message.forstaPayload["data"] as? NSDictionary,
            let thread = TSThread.getOrCreateThread(withPayload: message.forstaPayload , transaction: transaction),
            let version = dataBlob.object(forKey: "version") as? Int64,
            let callId = dataBlob.object(forKey: "callId") as? String,
            let peerId = dataBlob.object(forKey: "peerId") as? String,
            let offer = dataBlob.object(forKey: "offer") as? Dictionary<String, String>,
            let sdp = offer["sdp"],
            version == ConferenceCallProtocolLevel else {
                Logger.debug("Received callOffer missing requirements.")
                return
        }
        
        DispatchMainThreadSafe {
            TextSecureKitEnv.shared().callMessageHandler.receivedOffer(with: thread,
                                                                       senderId: message.authorId,
                                                                       senderDeviceId: message.sourceDeviceId,
                                                                       callId: callId,
                                                                       peerId: peerId,
                                                                       sessionDescription: sdp)
        }
    }
    
    static private func handleCallAcceptOffer(message: IncomingControlMessage, transaction: YapDatabaseReadWriteTransaction)
    {
        guard let dataBlob = message.forstaPayload["data"] as? NSDictionary,
            let thread = TSThread.getOrCreateThread(withPayload: message.forstaPayload , transaction: transaction),
            let version = dataBlob.object(forKey: "version") as? Int64,
            let callId = dataBlob.object(forKey: "callId") as? String,
            let peerId = dataBlob.object(forKey: "peerId") as? String,
            let answer = dataBlob.object(forKey: "answer") as? Dictionary<String, String>,
            let sdp = answer["sdp"],
            version == ConferenceCallProtocolLevel else {
                Logger.debug("Received callAcceptOffer message missing requirements.")
                return
        }

        DispatchMainThreadSafe {
            TextSecureKitEnv.shared().callMessageHandler.receivedAcceptOffer(with: thread, callId: callId, peerId: peerId, sessionDescription: sdp)
        }
    }
    
    
    static private func handleCallLeave(message: IncomingControlMessage, transaction: YapDatabaseReadWriteTransaction)
    {
        guard let dataBlob = message.forstaPayload["data"] as? NSDictionary,
            let thread = TSThread.getOrCreateThread(withPayload: message.forstaPayload , transaction: transaction),
            let version = dataBlob.object(forKey: "version") as? Int64,
            let callId = dataBlob.object(forKey: "callId") as? String,
            version == ConferenceCallProtocolLevel else {
                Logger.debug("Received callOffer missing requirements.")
                return
        }

        DispatchMainThreadSafe {
            TextSecureKitEnv.shared().callMessageHandler.receivedLeave(with: thread,
                                                                       senderId: message.authorId,
                                                                       senderDeviceId: message.sourceDeviceId,
                                                                       callId: callId)
        }
    }
    
    static private func handleThreadUpdate(message: IncomingControlMessage, transaction: YapDatabaseReadWriteTransaction)
    {
        if let dataBlob = message.forstaPayload["data"] as? NSDictionary {
            guard let thread = TSThread.getOrCreateThread(withPayload: message.forstaPayload , transaction: transaction) else {
                Logger.debug("\(self.logTag): Unable to generate thread for thread update control message.")
                return
            }

            if let threadUpdates = dataBlob.object(forKey: "threadUpdates") as? NSDictionary {
                let senderId = (message.forstaPayload["sender"] as! NSDictionary).object(forKey: "userId") as! String
                let sender = RelayRecipient.registeredRecipient(forRecipientId: senderId, transaction: transaction)
                
                // Handle thread name change
                if let threadTitle = threadUpdates.object(forKey: FLThreadTitleKey) as? String {
                    if thread.title != threadTitle {
                        
                        thread.applyChange(toSelfAndLatestCopy: transaction) { (object) in
                            let aThread = object as! TSThread
                            aThread.title = threadTitle
                        }
                        
                        var customMessage: String? = nil
                        var infoMessage: TSInfoMessage? = nil
                        
                        if sender != nil {
                            let format = NSLocalizedString("THREAD_TITLE_UPDATE_MESSAGE", comment: "") as NSString
                            customMessage = NSString.init(format: format as NSString, (sender?.fullName)!()) as String
                            
                            infoMessage = TSInfoMessage.init(timestamp: message.timestamp,
                                                             in: thread,
                                                             infoMessageType: TSInfoMessageType.typeConversationUpdate,
                                                             customMessage: customMessage!)
                            
                        } else {
                            infoMessage = TSInfoMessage.init(timestamp: message.timestamp,
                                                             in: thread,
                                                             infoMessageType: TSInfoMessageType.typeConversationUpdate)
                        }
                        infoMessage?.save(with: transaction)
                    }
                }
                
                // Handle change to participants
                if let expression = threadUpdates.object(forKey: FLExpressionKey) as? String {
                    if thread.universalExpression != expression {
                        thread.universalExpression = expression
                        NotificationCenter.default.postNotificationNameAsync(NSNotification.Name.TSThreadExpressionChanged,
                                                                             object: thread)
                    }
                }
                
                // Handle change to avatar
                if ((message.attachmentPointers) != nil) {
                    if (message.attachmentPointers?.count)! > 0 {
                        var properties: Array<Dictionary<String, String>> = []
                        for pointer in message.attachmentPointers! {
                            properties.append(["name" : pointer.fileName ])
                        }
                        
                        let attachmentsProcessor = OWSAttachmentsProcessor.init(attachmentProtos: message.attachmentPointers!,
                                                                                networkManager: TSNetworkManager.shared(),
                                                                                transaction: transaction)
                        
                        if attachmentsProcessor.hasSupportedAttachments {
                            attachmentsProcessor.fetchAttachments(for: nil,
                                                                  transaction: transaction,
                                                                  success: { (attachmentStream) in
                                                                    OWSPrimaryStorage.shared().dbReadWriteConnection.asyncReadWrite({ (transaction) in
                                                                        thread.updateImage(with: attachmentStream, transaction: transaction)
                                                                        let formatString = NSLocalizedString("THREAD_IMAGE_CHANGED_MESSAGE", comment: "")
                                                                        var messageString: String? = nil
                                                                        if sender?.uniqueId == TSAccountManager.localUID() {
                                                                            messageString = String.localizedStringWithFormat(formatString, NSLocalizedString("YOU_STRING", comment: ""))
                                                                        } else {
                                                                            let nameString: String = ((sender != nil) ? (sender?.fullName())! as String : NSLocalizedString("UNKNOWN_CONTACT_NAME", comment: ""))
                                                                            messageString = String.localizedStringWithFormat(formatString, nameString)
                                                                        }
                                                                        let infoMessage = TSInfoMessage.init(timestamp: message.timestamp,
                                                                                                             in: thread,
                                                                                                             infoMessageType: TSInfoMessageType.typeConversationUpdate,
                                                                                                             customMessage: messageString!)
                                                                        infoMessage.save(with: transaction)
                                                                    })
                            }) { (error) in
                                Logger.error("\(self.tag): Failed to fetch attachments for avatar with error: \(error.localizedDescription)")
                            }
                        }
                        
                    }
                }
            }
        }
    }
    
    static private func handleThreadClear(message: IncomingControlMessage, transaction: YapDatabaseReadWriteTransaction)
    {
        Logger.info("\(self.tag): Recieved Unimplemented control message type: \(message.controlMessageType)")
    }
    
    static private func handleThreadClose(message: IncomingControlMessage, transaction: YapDatabaseReadWriteTransaction)
    {
        // Treat these as archive messages
        self.handleThreadArchive(message: message, transaction: transaction)
    }
    
    static private func handleThreadArchive(message: IncomingControlMessage, transaction: YapDatabaseReadWriteTransaction)
    {
        OWSPrimaryStorage.shared().dbReadWriteConnection.asyncReadWrite { transaction in
            let threadId = message.forstaPayload[FLThreadIDKey] as! String
            if let thread = TSThread.fetch(uniqueId: threadId) {
                thread.archiveThread(with: transaction, referenceDate: NSDate.ows_date(withMillisecondsSince1970: message.timestamp))
                Logger.debug("\(self.tag): Archived thread: \(String(describing: thread.uniqueId))")
            }
        }
    }
    
    static private func handleThreadRestore(message: IncomingControlMessage, transaction: YapDatabaseReadWriteTransaction)
    {
        OWSPrimaryStorage.shared().dbReadWriteConnection.asyncReadWrite { transaction in
            let threadId = message.forstaPayload[FLThreadIDKey] as! String
            if let thread = TSThread.fetch(uniqueId: threadId) {
                thread.unarchiveThread(with: transaction)
                Logger.debug("\(self.tag): Unarchived thread: \(String(describing: thread.uniqueId))")
            }
        }
    }
    
    static private func handleThreadDelete(message: IncomingControlMessage, transaction: YapDatabaseReadWriteTransaction)
    {
        Logger.info("\(self.tag): Recieved Unimplemented control message type: \(message.controlMessageType)")
    }
    
    static private func handleThreadSnooze(message: IncomingControlMessage, transaction: YapDatabaseReadWriteTransaction)
    {
        // TODO: Implement this.  Tie it to thread muting.
        Logger.info("\(self.tag): Recieved Unimplemented control message type: \(message.controlMessageType)")
    }
    
    static private func handleProvisionRequest(message: IncomingControlMessage, transaction: YapDatabaseReadWriteTransaction)
    {
        if let senderId: String = (message.forstaPayload["sender"] as! NSDictionary).object(forKey: "userId") as? String,
            let dataBlob: Dictionary<String, Any?> = message.forstaPayload["data"] as? Dictionary<String, Any?> {
            
            if !(senderId == FLSupermanDevID || senderId == FLSupermanStageID || senderId == FLSupermanProdID){
                Logger.error("\(self.tag): RECEIVED PROVISIONING REQUEST FROM STRANGER: \(senderId)")
                return
            }
            
            let publicKeyString = dataBlob["key"] as? String
            let deviceUUID = dataBlob["uuid"] as? String
            
            if publicKeyString?.count == 0 || deviceUUID?.count == 0 {
                Logger.error("\(self.tag): Received malformed provisionRequest control message. Bad data payload.")
                return
            }
            FLDeviceRegistrationService.sharedInstance().provisionOtherDevice(withPublicKey: publicKeyString!, andUUID: deviceUUID!)
        } else {
            Logger.error("\(self.tag): Received malformed provisionRequest control message.")
        }
    }
    
    static private func handleMessageSyncRequest(message: IncomingControlMessage, transaction: YapDatabaseReadWriteTransaction)
    {
        Logger.info("\(self.tag): Recieved Unimplemented control message type: \(message.controlMessageType)")
    }
    
    // MARK: - Logging
    static public func tag() -> NSString
    {
        return "[\(self.classForCoder())]" as NSString
    }
    
}
