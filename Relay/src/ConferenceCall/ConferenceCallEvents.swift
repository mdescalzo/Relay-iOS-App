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
    
    static var all: String {
        var result = ""
        for event in events {
            result += event.toStr + "\n"
        }
        return result
    }
    
    static var lastCallEvents: [CCEContext] {
        let targetId = events.last!.callId
        let startAt = events.lastIndex(where: {cce in
            switch cce.event { case .CallInit(let callId): return callId == targetId default: return false }
        })
        return Array(events.dropFirst(startAt!))
    }
    
    static var lastCall: String {
        var result = ""
        for event in self.lastCallEvents {
            result += event.toStr + "\n"
        }
        return result
    }
    
    static var connectSpeeds: String {
        let events = self.lastCallEvents
        if events.count == 0 { return "(no call available)" }
        
        let users = Array(Set(events.filter({ e in e.userId != nil }).map({ e in e.userId! })))
        let usersData = users.map { (u: String) -> (String, [CCEContext]) in (u, events.filter { e in return e.userId == u }) }
        
        var report = "CALL \(events[0].callId) CONNECT SPEEDS\n"
        for (u, es) in usersData {
            report += "> user \(u):\n"
            var starts = [String:(String, Date)]()
            for e in es {
                switch e.event {
                case .PeerStateChange(_, let peerId, _, _, .sentAcceptOffer):
                    starts[peerId] = ("sent accept-offer to connect", e.timestamp)
                case .PeerStateChange(_, let peerId, _, _, .receivedAcceptOffer):
                    starts[peerId] = ("received accept-offer to connect", e.timestamp)
                default: ()
                }
            }
            for e in es {
                if case .PeerStateChange(_, let peerId, _, _, .connected) = e.event {
                    if starts[peerId] != nil {
                        let (dir, ts) = starts[peerId]!
                        report += "  > peer \(peerId): \(e.timestamp.msFrom(ts)) (\(dir))\n"
                        starts.removeValue(forKey: peerId)
                    } else {
                        report += "  > peer \(peerId): never set up to connect!?\n"
                    }
                }
            }
            for (k, _) in starts {
                report += "  > peer \(k): never finished connecting\n"
            }
        }
        return report
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
    func msFrom(_ t: Date) -> String {
        let ms = abs(round((self.timeIntervalSince(t) * 1000)))
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
    
    var callId: String {
        switch self.event {
        case .CallInit(let callId): return callId
        case .CallDeinit(let callId): return callId
        case .CallStateChange(let callId, _, _): return callId
        case .PeerInit(let callId, _, _): return callId
        case .PeerDeinit(let callId, _, _): return callId
        case .PeerStateChange(let callId, _, _, _, _): return callId
        case .ReceivedRemoteIce(let callId, _, _, _): return callId
        case .GeneratedLocalIce(let callId, _, _): return callId
        case .SentLocalIce(let callId, _, _, _): return callId
        }
    }
    
    var userId: String? {
        switch self.event {
        case .CallInit(_): return nil
        case .CallDeinit(_): return nil
        case .CallStateChange(_, _, _): return nil
        case .PeerInit(_, _, let uid): return uid
        case .PeerDeinit(_, _, let uid): return uid
        case .PeerStateChange(_, _, let uid, _, _): return uid
        case .ReceivedRemoteIce(_, _, let uid, _): return uid
        case .GeneratedLocalIce(_, _, let uid): return uid
        case .SentLocalIce(_, _, let uid, _): return uid
        }
    }
}

