//
//  ConferenceCallEvents.swift
//  Relay
//
//  Created by Greg Perkins on 2/15/19.
//  Copyright © 2019 Forsta Labs, Inc. All rights reserved.
//

import Foundation

public class ConferenceCallEvents {
    static var events = [CCEContext]()
    static var epoch = Date()
    
    static func add(_ event: ConferenceCallEvent) {
        self.events.append(CCEContext(Date(), Thread.current.threadName, event))
        Logger.info("\n\(self.events.last!.toStr)\n")
    }
    
    // summarize most recent call
    static func callSummary() {
    }
}

public class CCEContext {
    var timestamp: Date
    var thread: String
    var event: ConferenceCallEvent
    
    init(_ timestamp: Date, _ thread: String, _ event: ConferenceCallEvent) {
        self.timestamp = timestamp
        self.thread = thread
        self.event = event
    }
}

enum ConferenceCallEvent {
    case CallInit(
        callId: String
    )
    case CallDeinit(
        callId: String
    )
    case CallStateChange(
        callId: String,
        oldState: ConferenceCallState,
        newState: ConferenceCallState
    )
    case PeerInit(
        callId: String,
        peerId: String,
        userId: String
    )
    case PeerDeinit(
        callId: String,
        peerId: String,
        userId: String
    )
    case PeerStateChange(
        callId: String,
        peerId: String,
        userId: String,
        oldState: PeerConnectionClientState,
        newState: PeerConnectionClientState
    )
    case ReceivedRemoteIce(
        callId: String,
        peerId: String,
        userId: String,
        count: Int
    )
    case GeneratedLocalIce(
        callId: String,
        peerId: String,
        userId: String
    )
    case SentLocalIce(
        callId: String,
        peerId: String,
        userId: String,
        count: Int
    )
}

extension Thread {
    var threadName: String {
        if let currentOperationQueue = OperationQueue.current?.name {
            return "OperationQueue: \(currentOperationQueue)"
        } else if let underlyingDispatchQueue = OperationQueue.current?.underlyingQueue?.label {
            return "DispatchQueue: \(underlyingDispatchQueue)"
        } else {
            let name = __dispatch_queue_get_label(nil)
            return String(cString: name, encoding: .utf8) ?? Thread.current.description
        }
    }
}

extension Formatter {
    static let withCommas: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.groupingSeparator = ","
        formatter.numberStyle = .decimal
        formatter.minimumIntegerDigits = 6
        return formatter
    }()
}
extension Double {
    var formattedWithCommas: String {
        return Formatter.withCommas.string(for: self) ?? ""
    }
}
extension Date {
    var msFromEpoch: String {
        let ms = abs(round((self.timeIntervalSince(ConferenceCallEvents.epoch) * 1000)))
        return "\(ms.formattedWithCommas)ms"
    }
}

extension CCEContext {
    var toStr: String {
        let prefix = "CCE "
        switch self.event {
        case .CallInit(let callId):
            return "\(prefix)\(timestamp.msFromEpoch) call init: \(callId) thread \(thread)"
        case .CallDeinit(let callId):
            return "\(prefix)\(timestamp.msFromEpoch) call DEinit: \(callId) thread \(thread)"
        case .CallStateChange(let callId, let oldState, let newState):
            return "\(prefix)\(timestamp.msFromEpoch) call state: \(oldState)->\(newState) \(callId) thread \(thread)"
        case .PeerInit(let callId, let peerId, _):
            return "\(prefix)\(timestamp.msFromEpoch) peer init: \(peerId) call \(callId) thread \(thread)"
        case .PeerDeinit(let callId, let peerId, _):
            return "\(prefix)\(timestamp.msFromEpoch) peer DEinit: \(peerId) call \(callId) thread \(thread)"
        case .PeerStateChange(let callId, let peerId, let userId, let oldState, let newState):
            return "\(prefix)\(timestamp.msFromEpoch) peer state: \(oldState)->\(newState) peer \(peerId) user \(userId) call \(callId) thread \(thread)"
        case .ReceivedRemoteIce(let callId, let peerId, _, let count):
            return "\(prefix)\(timestamp.msFromEpoch) received \(count) remote ice: peer \(peerId) call \(callId) thread \(thread)"
        case .GeneratedLocalIce(let callId, let peerId, _):
            return "\(prefix)\(timestamp.msFromEpoch) buffered 1 local ice: peer \(peerId) call \(callId) thread \(thread)"
        case .SentLocalIce(let callId, let peerId, _, let count):
            return "\(prefix)\(timestamp.msFromEpoch) sent \(count) local ice: peer \(peerId) call \(callId) thread \(thread)"
        }
    }
}

