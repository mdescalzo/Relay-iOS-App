//
//  MessageManager.swift
//  RelayMessaging
//
//  Created by Mark on 5/28/19.
//  Copyright © 2019 Forsta Labs, Inc. All rights reserved.
//

// PURPOSE: Take an incoming payload dictionary and build the appropriate messaging object

// TODO: Assorted error states should throw

import Foundation

enum MessagePayloadKey : String {
    case version = "version"
    case messageId = "messageId"
    case messageType = "messageType"
    case threadId = "threadId"
    case threadType = "threadType"
    case threadTitle = "threadTitle"
    case data = "data"
    case distribution = "distribution"
    case privateResponses = "privateResponses"
    case disableResponses = "disableResponses"
    case messageRef = "messageRef"
}

enum MessageDataKey : String {
    case receipt = "receipt"
    case body = "body"
    case attachments = "attachments"
    case mentions = "mentions"
    case pollMaxSelections = "pollMaxSelections"
    case pollChoices = "pollChoices"
    case pollSelections = "pollSelections"
    case expiration = "expiration"
    case control = "control"
    case threadUpdates = "threadUpdates"
    case readMark = "readMark"
    case snoozeUntil = "snoozeUntil"
    case threadDiscoveryCandidates = "threadDiscoveryCandidates"
    case syncRequest = "syncRequest"
    case syncResponse = "syncResponse"
    case aclRequest = "aclRequest"
    case aclResponse = "aclResponse"
    case retransmits = "retransmits"
}

enum MessageControlKey : String {
    case threadUpdate = "threadUpdate"
    case threadClear = "threadClear"
    case threadArchive = "threadArchive"
    case threadRestore = "threadRestore"
    case threadDelete = "threadDelete"
    case readMark = "readMark"
    case pendingMessage = "pendingMessage"
    case snooze = "snooze"
    case provisionRequest = "provisionRequest"
    case syncRequest = "syncRequest"
    case syncResponse = "syncResponse"
    case discoverRequest = "discoverRequest"
    case discoverResponse = "discoverResponse"
    case preMessageCheck = "preMessageCheck"
    case aclRequest = "aclRequest"
    case aclResponse = "aclResponse"
    case userBlock = "userBlock"
    case userUnblock = "userUnblock"
    case beacon = "beacon"
    case closeSession = "closeSession"
    case callJoin = "callJoin"
    case callLeave = "callLeave"
    case callOffer = "callOffer"
    case callAcceptOffer = "callAcceptOffer"
    case callICECandidates = "callICECandidates"
}

enum MessageType : String {
    case content = "content"
    case poll = "poll"
    case pollResponse = "pollResponse"
    case control = "control"
    case receipt = "receipt"
}

enum BodyKey : String {
    case type = "type"
    case value = "value"
}


enum ThreadTypeKey : String {
    case conversation = "conversation"
    case announcement = "announcement"
}

@objc
class MessageManager : NSObject {
    
    public func processPayload(_ payload: [MessagePayloadKey : AnyObject]) {
        
        guard let version = payload[.version] as? NSNumber else {
            print("Invalid payload:  Unknown message version.")
            return
        }
        
        if version == 1 {
            guard let messageType = payload[.messageType] as? MessageType else {
                print("Invalid payload:  Missing messageType object.")
                return
            }
            

            switch messageType {
            case .content: do {
                processContentMessagePayload(payload)
                break
                }
            case .control: do {
                // TODO:  Handle control message
                break
                }
            case .poll: do {
                // TODO: Handle poll message
                break
                }
            case .pollResponse: do {
                // TODO: Handle pollResponse message
                break
                }
            case .receipt: do {
                // TODO: Handle receipt message
                break
                }
            }
            
            
        } else {
            print("Unhandled message version: \(version)")
            return
        }
    }
    
    private func processContentMessagePayload(_ payload: [MessagePayloadKey: AnyObject]) {
        guard let messageId = payload[.messageId] as? String else {
            print("Message missing unique Id string.")
            return
        }
        guard let threadId = payload[.threadId] as? String else {
            print("Message missing unique thread Id string.")
            return
        }
        guard let threadType = payload[.threadType] as? String else {
            print("Message missing thread type string.")
            return
        }
        guard let dataBlob = payload[.data] as? [MessageDataKey: AnyObject] else {
            print("Message missing data object.")
            return
        }
        var threadTitle = payload[.threadTitle] as? String

        guard let bodyBlob = dataBlob[.body] as? [[BodyKey: String]] else {
            print("Content message missing or invalid body.")
            return
        }
        
        var htmlBody: String? = nil
        var plainBody: String? = nil
        for bodyPart in bodyBlob {
            switch bodyPart[.type] {
            case "text/plain": do {
                plainBody = bodyPart[.value]
                break
                }
            case "text/html": do {
                htmlBody = bodyPart[.value]
                break
                }
            default: do {
                print("Unhandled body type: \(String(describing: bodyPart[.type]))")
                break
                }
            }
        }
        
        guard htmlBody != nil || plainBody != nil else {
            print("No body string provided in message: \(messageId)")
            return
        }
    }
}
