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
        Logger.info("Received readMark message: \(message.forstaPayload)")
        
        guard let dataBlob = message.forstaPayload.object(forKey: "data") as? NSDictionary else {
            Logger.debug("Received readMark message with no data blob.")
            return
        }

        guard let threadId = message.forstaPayload.object(forKey: "threadId") as? String else {
            Logger.debug("Received readMark message with no threadId.")
            return
        }
        guard let senderId = (message.forstaPayload.object(forKey: "sender") as! NSDictionary).object(forKey: "userId") as? String else {
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
        Logger.info("Received callICECandidates message: \(message.forstaPayload)")
        
        if let dataBlob = message.forstaPayload.object(forKey: "data") as? NSDictionary {
            
            guard let callId: String = dataBlob.object(forKey: "callId") as? String else {
                Logger.debug("Received callICECandidates message with no callId.")
                return
            }
            
            guard let peerId: String = dataBlob.object(forKey: "peerId") as? String else {
                Logger.debug("Received callICECandidates message with no peerId.")
                return
            }

            guard let iceCandidates: [NSDictionary] = dataBlob.object(forKey: "icecandidates") as? [NSDictionary] else {
                Logger.debug("Received callICECandidates message with no candidates.")
                return
            }
            
            DispatchMainThreadSafe {
                TextSecureKitEnv.shared().callMessageHandler.receivedIceCandidates(with: message.thread,
                                                                                   callId: callId,
                                                                                   peerId: peerId,
                                                                                   iceCandidates: iceCandidates);
            
            }
        }
    }
    
    static private func handleCallOffer(message: IncomingControlMessage, transaction: YapDatabaseReadWriteTransaction)
    {
        guard #available(iOS 10.0, *) else {
            Logger.info("\(self.tag): Ignoring callOffer control message due to iOS version.")
            return
        }
        
        let forstaPayload = message.forstaPayload as NSDictionary
        
        let dataBlob = forstaPayload.object(forKey: "data") as? NSDictionary
        let threadId = forstaPayload.object(forKey: "threadId") as? String
        
        guard dataBlob != nil else {
            Logger.info("Received callOffer message with no data object.")
            return
        }
        
        guard let callId = dataBlob?.object(forKey: "callId") as? String,
            let members = dataBlob?.object(forKey: "members") as? NSArray,
            let originator = dataBlob?.object(forKey: "originator") as? String,
            let peerId = dataBlob?.object(forKey: "peerId") as? String,
            let offer = dataBlob?.object(forKey: "offer") as? NSDictionary else {
            Logger.debug("Received callOffer message missing required objects.")
            return
        }
        
        let sdpString = offer.object(forKey: "sdp") as? String
        
        guard sdpString != nil else {
            Logger.debug("sdb string missing from callOffer.")
            return
        }
        
        let thread = message.thread
        thread.update(withPayload: forstaPayload as! [AnyHashable : Any])
        thread.participantIds = members as! [String]
        thread.save(with: transaction)
        
        DispatchMainThreadSafe {
            TextSecureKitEnv.shared().callMessageHandler.receivedOffer(with: thread,
                                                                       callId: callId,
                                                                       senderId: message.authorId,
                                                                       peerId: peerId,
                                                                       originatorId: originator,
                                                                       sessionDescription: sdpString!)
        }
    }
    
    static private func handleCallAcceptOffer(message: IncomingControlMessage, transaction: YapDatabaseReadWriteTransaction)
    {
        Logger.debug("Received callAcceptOffer message: \(message.forstaPayload)")
        
        guard let dataBlob = message.forstaPayload.object(forKey: "data") as? NSDictionary else {
            Logger.debug("Received callAcceptOffer message with no data object.")
            return
        }

        guard let callId = dataBlob.object(forKey: "callId") as? String else {
            Logger.debug("Received callAcceptOffer message without callId.")
            return
        }

        guard let peerId = dataBlob.object(forKey: "peerId") as? String else {
            Logger.debug("Received callAcceptOffer message without peerId.")
            return
        }
        
        guard let answer = dataBlob["answer"] as? Dictionary<String, String>  else {
            Logger.debug("Received callAcceptOffer message without answer object.")
            return
        }
        
        guard let sdp = answer["sdp"] else {
            Logger.debug("Received callAcceptOffer message without session description.")
            return
        }
        
        // If the callAccept came from self, another device picked up.  Stop local processing.
        guard message.authorId != TSAccountManager.localUID() else {
            Logger.info("Another device of self has answered a call")
            let deviceId = message.sourceDeviceId
            DispatchMainThreadSafe {
                TextSecureKitEnv.shared().callMessageHandler.receivedSelfAcceptOffer(with: message.thread, callId: callId, deviceId: deviceId)
            }
            return
        }
        
        DispatchMainThreadSafe {
            TextSecureKitEnv.shared().callMessageHandler.receivedAcceptOffer(with: message.thread, callId: callId, peerId: peerId, sessionDescription: sdp)
        }
    }
    
    
    static private func handleCallLeave(message: IncomingControlMessage, transaction: YapDatabaseReadWriteTransaction)
    {
        Logger.debug("Received callLeave message: \(message.forstaPayload)")

        guard let dataBlob = message.forstaPayload.object(forKey: "data") as? NSDictionary else {
            Logger.info("Received callLeave message with no data object.")
            return
        }

        guard let callId = dataBlob.object(forKey: "callId") as? String else {
            Logger.info("Received callLeave message without callId.")
            return
        }
        
        guard let senderId = (message.forstaPayload.object(forKey: "sender") as! NSDictionary).object(forKey: "userId") as? String else {
            Logger.debug("Received callLeave message with no senderId.")
            return
        }
        
        DispatchMainThreadSafe {
            TextSecureKitEnv.shared().callMessageHandler.receivedLeave(with: message.thread, callId: callId, senderId: senderId)
        }
    }
    
    static private func handleThreadUpdate(message: IncomingControlMessage, transaction: YapDatabaseReadWriteTransaction)
    {
        if let dataBlob = message.forstaPayload.object(forKey: "data") as? NSDictionary {
            if let threadUpdates = dataBlob.object(forKey: "threadUpdates") as? NSDictionary {
                
                let thread = message.thread
                let senderId = (message.forstaPayload.object(forKey: "sender") as! NSDictionary).object(forKey: "userId") as! String
                
                let sender = RelayRecipient.registeredRecipient(forRecipientId: senderId, transaction: transaction)
                
                // Handle thread name change
                if let threadTitle = threadUpdates.object(forKey: FLThreadTitleKey) as? String {
                    if thread.title != threadTitle {
                        thread.title = threadTitle
                        
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
                        thread.save(with: transaction)
                    }
                }
                
                // Handle change to participants
                if let expression = threadUpdates.object(forKey: FLExpressionKey) as? String {
                    if thread.universalExpression != expression {
                        
                        thread.universalExpression = expression
                        
                        NotificationCenter.default.post(name: NSNotification.Name.TSThreadExpressionChanged,
                                                        object: thread,
                                                        userInfo: nil)
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
                                                                        thread.image = attachmentStream.image()
                                                                        thread.save(with: transaction)
                                                                        attachmentStream.remove(with: transaction)
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
            let threadId = message.forstaPayload.object(forKey: FLThreadIDKey) as! String
            if let thread = TSThread.fetch(uniqueId: threadId) {
                thread.archiveThread(with: transaction, referenceDate: NSDate.ows_date(withMillisecondsSince1970: message.timestamp))
                Logger.debug("\(self.tag): Archived thread: \(String(describing: thread.uniqueId))")
            }
        }
    }
    
    static private func handleThreadRestore(message: IncomingControlMessage, transaction: YapDatabaseReadWriteTransaction)
    {
        OWSPrimaryStorage.shared().dbReadWriteConnection.asyncReadWrite { transaction in
            let threadId = message.forstaPayload.object(forKey: FLThreadIDKey) as! String
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
        Logger.info("\(self.tag): Recieved Unimplemented control message type: \(message.controlMessageType)")
    }
    
    static private func handleProvisionRequest(message: IncomingControlMessage, transaction: YapDatabaseReadWriteTransaction)
    {
        if let senderId: String = (message.forstaPayload.object(forKey: "sender") as! NSDictionary).object(forKey: "userId") as? String,
            let dataBlob: Dictionary<String, Any?> = message.forstaPayload.object(forKey: "data") as? Dictionary<String, Any?> {
            
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
