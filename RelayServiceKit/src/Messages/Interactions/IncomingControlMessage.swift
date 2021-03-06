//
//  IncomingControlMessage.swift
//  Forsta
//
//  Created by Mark Descalzo on 6/22/18.
//  Copyright © 2018 Forsta. All rights reserved.
//

import UIKit

@objc public class IncomingControlMessage: TSIncomingMessage {
    
    @objc let controlMessageType: String
    @objc let attachmentPointers: Array<OWSSignalServiceProtosAttachmentPointer>?
    
    @objc required public init?(timestamp: UInt64,
                                serverAge: NSNumber?,
                                author: String,
                                device: UInt32,
                                payload: NSDictionary,
                                attachments: Array<OWSSignalServiceProtosAttachmentPointer>?) {
        
        let messageType = payload.object(forKey: "messageType") as! String
        
        if (messageType.count == 0) {
            Logger.error("Attempted to create control message with invalid payload.");
            return nil
        }
        
        let dataBlob = payload.object(forKey: "data") as! NSDictionary
        if dataBlob.allKeys.count == 0 {
            Logger.error("Attempted to create control message without data object.")
            return nil
        }
        
        let controlType = dataBlob.object(forKey: FLMessageTypeControlKey) as! String
        if controlType.count == 0 {
            Logger.error("Attempted to create control message without a type.")
            return nil
        }
        
        self.attachmentPointers = attachments
        self.controlMessageType = dataBlob.object(forKey: FLMessageTypeControlKey) as! String
        
        var attachmentIds:[String] = []
        if ((dataBlob.object(forKey: "attachments")) != nil) {
            attachmentIds = dataBlob.object(forKey: "attachments") as! [String]
        }

        super.init(incomingMessageWithTimestamp: timestamp,
                   serverAge:serverAge,
                   in: nil,
                   authorId: author,
                   sourceDeviceId: device,
                   messageBody: nil,
                   attachmentIds: attachmentIds,
                   expiresInSeconds: 0,
                   quotedMessage: nil)
                
        self.messageType = FLMessageTypeControlKey
        self.forstaPayload = payload.copy() as! [AnyHashable : Any]
    }
    
    @objc required public init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    @objc required public init(dictionary dictionaryValue: [AnyHashable : Any]!) throws {
        fatalError("init(dictionary:) has not been implemented")
    }
    
    @objc override public func previewText(with transaction: YapDatabaseReadTransaction) -> String {
        return ""
    }
}
