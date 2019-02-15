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
    static var eventsEpoch = Date()
    
    static func add(_ event: ConferenceCallEvent) {
        self.events.append(event)
        Logger.info("\n\(event.str(self.eventsEpoch))\n")
    }
}

enum ConferenceCallEvent {
    case CallStateChange(timestamp: Date,
        callId: String,
        oldState: ConferenceCallState,
        newState: ConferenceCallState)
    case PeerStateChange(timestamp: Date,
        callId: String,
        peerId: String,
        userId: String,
        oldState: PeerConnectionClientState,
        newState: PeerConnectionClientState)
}

extension Formatter {
    static let withCommas: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.groupingSeparator = ","
        formatter.numberStyle = .decimal
        return formatter
    }()
}
extension Double {
    var formattedWithCommas: String {
        return Formatter.withCommas.string(for: self) ?? ""
    }
}

extension ConferenceCallEvent {
    func str(_ epoch: Date) -> String {
        switch self {
        case .CallStateChange(timestamp: let timestamp, callId: let callId, oldState: let oldState, newState: let newState):
            let ms = round((timestamp.timeIntervalSince(epoch) * 1000))
            return "call transition: \(oldState)->\(newState) @ \(ms.formattedWithCommas)ms call \(callId)"
        case .PeerStateChange(timestamp: let timestamp, callId: let callId, peerId: let peerId, userId: let userId, oldState: let oldState, newState: let newState):
            let ms = round((timestamp.timeIntervalSince(epoch) * 1000))
            return "peer transition: \(oldState)->\(newState) @ \(ms.formattedWithCommas)ms peer \(peerId) user \(userId) call \(callId)"
        }
    }
}

