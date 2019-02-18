//
//  ConferenceCallEvents.swift
//  Relay
//
//  Created by Greg Perkins on 2/15/19.
//  Copyright © 2019 Forsta Labs, Inc. All rights reserved.
//

import Foundation

public class ConferenceCallEvents {
    static var events = [ConferenceCallEvent]()
    static var epoch = Date()
    
    static func add(_ event: ConferenceCallEvent) {
        self.events.append(event)
        Logger.info("\n\(event.toStr)\n")
    }
}

enum ConferenceCallEvent {
    case CallInit(
        timestamp: Date,
        callId: String
    )
    case CallDeinit(
        timestamp: Date,
        callId: String
    )
    case CallStateChange(
        timestamp: Date,
        callId: String,
        oldState: ConferenceCallState,
        newState: ConferenceCallState
    )
    case PeerInit(
        timestamp: Date,
        callId: String,
        peerId: String,
        userId: String
    )
    case PeerDeinit(
        timestamp: Date,
        callId: String,
        peerId: String,
        userId: String
    )
    case PeerStateChange(
        timestamp: Date,
        callId: String,
        peerId: String,
        userId: String,
        oldState: PeerConnectionClientState,
        newState: PeerConnectionClientState
    )
    case ReceivedRemoteIce(
        timestamp: Date,
        callId: String,
        peerId: String,
        userId: String,
        count: Int
    )
    case GeneratedLocalIce(
        timestamp: Date,
        callId: String,
        peerId: String,
        userId: String
    )
    case SentLocalIce(
        timestamp: Date,
        callId: String,
        peerId: String,
        userId: String,
        count: Int
    )
}

extension Formatter {
    static let withCommas: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.groupingSeparator = ","
        formatter.numberStyle = .decimal
        formatter.minimumIntegerDigits = 7
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

extension ConferenceCallEvent {
    var toStr: String {
        let prefix = "CCE "
        switch self {
        case .CallInit(let timestamp, let callId):
            return "\(prefix)\(timestamp.msFromEpoch) call init: \(callId)"
        case .CallDeinit(let timestamp, let callId):
            return "\(prefix)\(timestamp.msFromEpoch) call deinit: \(callId)"
        case .CallStateChange(let timestamp, let callId, let oldState, let newState):
            return "\(prefix)\(timestamp.msFromEpoch) call state: \(oldState)->\(newState) \(callId)"
        case .PeerInit(let timestamp, let callId, let peerId, _):
            return "\(prefix)\(timestamp.msFromEpoch) peer init: \(peerId) call \(callId)"
        case .PeerDeinit(let timestamp, let callId, let peerId, _):
            return "\(prefix)\(timestamp.msFromEpoch) peer deinit: \(peerId) call \(callId)"
        case .PeerStateChange(let timestamp, let callId, let peerId, let userId, let oldState, let newState):
            return "\(prefix)\(timestamp.msFromEpoch) peer state: \(oldState)->\(newState) peer \(peerId) user \(userId) call \(callId)"
        case .ReceivedRemoteIce(let timestamp, let callId, let peerId, _, let count):
            return "\(prefix)\(timestamp.msFromEpoch) received \(count) remote ice: peer \(peerId) call \(callId)"
        case .GeneratedLocalIce(let timestamp, let callId, let peerId, _):
            return "\(prefix)\(timestamp.msFromEpoch) buffered 1 local ice: peer \(peerId) call \(callId)"
        case .SentLocalIce(let timestamp, let callId, let peerId, _, let count):
            return "\(prefix)\(timestamp.msFromEpoch) sent \(count) local ice: peer \(peerId) call \(callId)"
        }
    }
}

