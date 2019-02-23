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
    static var level = CCERenderLevel.long
    
    static func add(_ event: ConferenceCallEvent) {
        self.events.append(CCEContext(Date(), Thread.current.threadName, event))
        Logger.info("\n\(self.events.last!.render(self.level))")
    }
    
    static var all: String {
        var result = ""
        for event in events {
            result += event.render(.brief)
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
            result += event.render(.brief)
        }
        return result
    }
    
    static var connectSpeeds: String {
        let events = self.lastCallEvents
        if events.count == 0 { return "(no call available)" }
        
        let users = Array(Set(events.filter({ e in e.userSelector != nil }).map({ e in e.userSelector! })))
        let usersData = users.map { (u: String) -> (String, [CCEContext]) in (u, events.filter { e in return e.userSelector == u }) }
        
        var report = "CALL \(events[0].callId) CONNECT SPEEDS\n"
        for (u, es) in usersData {
            report += "> user \(u):\n"
            var starts = [String:(String, Date)]()
            for e in es {
                switch e.event {
                case .PeerStateChange(_, let peerId, _, _, _, .sentAcceptOffer):
                    starts[peerId] = ("sent accept-offer to connect", e.timestamp)
                case .PeerStateChange(_, let peerId, _, _, _, .receivedAcceptOffer):
                    starts[peerId] = ("received accept-offer to connect", e.timestamp)
                default: ()
                }
            }
            for e in es {
                // if case .PeerStateChange(_, let peerId, _, _, .connected) = e.event {
                if case .PeerStateChange(_, let peerId, _, _, _, .connected) = e.event {
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
    case SentCallJoin(
        callId: String
    )
    case SentCallLeave(
        callId: String
    )
    case ReceivedCallJoin(
        callId: String,
        userId: String,
        deviceId: UInt32
    )
    case ReceivedCallLeave(
        callId: String,
        userId: String,
        deviceId: UInt32
    )
    case CallStateChange(
        callId: String,
        oldState: ConferenceCallState,
        newState: ConferenceCallState
    )
    case PeerInit(
        callId: String,
        peerId: String,
        userId: String,
        deviceId: UInt32
    )
    case PeerDeinit(
        callId: String,
        peerId: String,
        userId: String,
        deviceId: UInt32
    )
    case PeerStateChange(
        callId: String,
        peerId: String,
        userId: String,
        deviceId: UInt32,
        oldState: PeerConnectionClientState,
        newState: PeerConnectionClientState
    )
    case ReceivedRemoteIce(
        callId: String,
        peerId: String,
        userId: String,
        deviceId: UInt32,
        count: Int
    )
    case GeneratedLocalIce(
        callId: String,
        peerId: String,
        userId: String,
        deviceId: UInt32
    )
    case SentLocalIce(
        callId: String,
        peerId: String,
        userId: String,
        deviceId: UInt32,
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

enum CCERenderLevel {
    case full, long, brief
}

extension CCEContext {
    func render(_ level: CCERenderLevel) -> String {
        let prefix = "CCE "
        switch self.event {
        case .CallInit(let callId):
            switch level {
            case .full: return "\(prefix)\(timestamp.msFromEpoch) call init: \(callId) thread \(thread)\n"
            case .long: return "\(prefix)\(timestamp.msFromEpoch) call init: \(callId)\n"
            case .brief: return "\(timestamp.msFromEpoch) call init: \(callId)\n"
            }
        case .CallDeinit(let callId):
            switch level {
            case .full: return "\(prefix)\(timestamp.msFromEpoch) call deinit: \(callId) thread \(thread)\n"
            case .long: return "\(prefix)\(timestamp.msFromEpoch) call deinit: \(callId)\n"
            case .brief: return "\(timestamp.msFromEpoch) call deinit: \(callId)\n"
            }
        case .SentCallJoin(let callId):
            switch level {
            case .full: return "\(prefix)\(timestamp.msFromEpoch) call join sent: \(callId) thread \(thread)\n"
            case .long: return "\(prefix)\(timestamp.msFromEpoch) call join sent: \(callId)\n"
            case .brief: return "\(timestamp.msFromEpoch) call join sent: \(callId)\n"
            }
        case .SentCallLeave(let callId):
            switch level {
            case .full: return "\(prefix)\(timestamp.msFromEpoch) call leave sent: \(callId) thread \(thread)\n"
            case .long: return "\(prefix)\(timestamp.msFromEpoch) call leave sent: \(callId)\n"
            case .brief: return "\(timestamp.msFromEpoch) call leave sent: \(callId)\n"
            }
        case .ReceivedCallJoin(let callId, let userId, let deviceId):
            switch level {
            case .full: return "\(prefix)\(timestamp.msFromEpoch) call join received: \(callId) user.device \(userId).\(deviceId) thread \(thread)\n"
            case .long: return "\(prefix)\(timestamp.msFromEpoch) call join received: \(callId) user.device \(userId).\(deviceId)\n"
            case .brief: return "\(timestamp.msFromEpoch) call join received: \(callId) user.device \(userId).\(deviceId)\n"
            }
        case .ReceivedCallLeave(let callId, let userId, let deviceId):
            switch level {
            case .full: return "\(prefix)\(timestamp.msFromEpoch) call leave received: \(callId) user.device \(userId).\(deviceId) thread \(thread)\n"
            case .long: return "\(prefix)\(timestamp.msFromEpoch) call leave received: \(callId) user.device \(userId).\(deviceId)\n"
            case .brief: return "\(timestamp.msFromEpoch) call leave received: \(callId) user.device \(userId).\(deviceId)\n"
            }
        case .CallStateChange(let callId, let oldState, let newState):
            switch level {
            case .full: return "\(prefix)\(timestamp.msFromEpoch) call \(oldState)->\(newState) \(callId) thread \(thread)\n"
            case .long: return "\(prefix)\(timestamp.msFromEpoch) call \(oldState)->\(newState) \(callId)\n"
            case .brief: return "\(timestamp.msFromEpoch) call \(oldState)->\(newState) \(callId)\n"
            }
        case .PeerInit(let callId, let peerId, let userId, let deviceId):
            switch level {
            case .full: return "\(prefix)\(timestamp.msFromEpoch) peer init: \(peerId) call \(callId) user.device \(userId).\(deviceId) thread \(thread)\n"
            case .long: return "\(prefix)\(timestamp.msFromEpoch) peer init: \(peerId) call \(callId) user.device \(userId).\(deviceId)\n"
            case .brief: return "\(timestamp.msFromEpoch) peer init: \(peerId) call \(callId) user.device \(userId).\(deviceId)\n"
            }
        case .PeerDeinit(let callId, let peerId, let userId, let deviceId):
            switch level {
            case .full: return "\(prefix)\(timestamp.msFromEpoch) peer deinit: \(peerId) call \(callId) user.device \(userId).\(deviceId) thread \(thread)\n"
            case .long: return "\(prefix)\(timestamp.msFromEpoch) peer deinit: \(peerId) call \(callId) user.device \(userId).\(deviceId)\n"
            case .brief: return "\(timestamp.msFromEpoch) peer deinit: \(peerId)\n"
            }
        case .PeerStateChange(let callId, let peerId, let userId, let deviceId, let oldState, let newState):
            switch level {
            case .full: return "\(prefix)\(timestamp.msFromEpoch) peer \(oldState)->\(newState) \(peerId) user.device \(userId).\(deviceId) call \(callId) thread \(thread)\n"
            case .long: return "\(prefix)\(timestamp.msFromEpoch) peer \(oldState)->\(newState) \(peerId) user.device \(userId).\(deviceId) call \(callId)\n"
            case .brief: return "\(timestamp.msFromEpoch) peer \(oldState)->\(newState) \(peerId)\n"
            }
        case .ReceivedRemoteIce(let callId, let peerId, let userId, let deviceId, let count):
            switch level {
            case .full: return "\(prefix)\(timestamp.msFromEpoch) received \(count) remote ice: peer \(peerId) user.device \(userId).\(deviceId) call \(callId) thread \(thread)\n"
            case .long: return "\(prefix)\(timestamp.msFromEpoch) received \(count) remote ice: peer \(peerId) user.device \(userId).\(deviceId) call \(callId)\n"
            case .brief: return "\(timestamp.msFromEpoch) received \(count) remote ice from peer \(peerId)\n"
            }
        case .GeneratedLocalIce(let callId, let peerId, let userId, let deviceId):
            switch level {
            case .full: return "\(prefix)\(timestamp.msFromEpoch) buffered 1 local ice: peer \(peerId) user.device \(userId).\(deviceId) call \(callId) thread \(thread)\n"
            case .long: return "\(prefix)\(timestamp.msFromEpoch) buffered 1 local ice: peer \(peerId) user.device \(userId).\(deviceId) call \(callId)\n"
            case .brief: return ""
            }
        case .SentLocalIce(let callId, let peerId, let userId, let deviceId, let count):
            switch level {
            case .full: return "\(prefix)\(timestamp.msFromEpoch) sent \(count) local ice: peer \(peerId) user.device \(userId).\(deviceId) call \(callId) thread \(thread)\n"
            case .long: return "\(prefix)\(timestamp.msFromEpoch) sent \(count) local ice: peer \(peerId) user.device \(userId).\(deviceId) call \(callId)\n"
            case .brief: return "\(timestamp.msFromEpoch) sent \(count) local ice to peer \(peerId)\n"
            }
        }
    }

    var callId: String {
        switch self.event {
        case .CallInit(let callId): return callId
        case .CallDeinit(let callId): return callId
        case .SentCallJoin(let callId): return callId
        case .SentCallLeave(let callId): return callId
        case .ReceivedCallJoin(let callId, _, _): return callId
        case .ReceivedCallLeave(let callId, _, _): return callId
        case .CallStateChange(let callId, _, _): return callId
        case .PeerInit(let callId, _, _, _): return callId
        case .PeerDeinit(let callId, _, _, _): return callId
        case .PeerStateChange(let callId, _, _, _, _, _): return callId
        case .ReceivedRemoteIce(let callId, _, _, _, _): return callId
        case .GeneratedLocalIce(let callId, _, _, _): return callId
        case .SentLocalIce(let callId, _, _, _, _): return callId
        }
    }
    
    var userSelector: String? {
        switch self.event {
        case .CallInit(_): return nil
        case .CallDeinit(_): return nil
        case .SentCallJoin(_): return nil
        case .SentCallLeave(_): return nil
        case .ReceivedCallJoin(_, let userId, let deviceId): return "\(userId).\(deviceId)"
        case .ReceivedCallLeave(_, let userId, let deviceId): return "\(userId).\(deviceId)"
        case .CallStateChange(_, _, _): return nil
        case .PeerInit(_, _, let userId, let deviceId): return "\(userId).\(deviceId)"
        case .PeerDeinit(_, _, let userId, let deviceId): return "\(userId).\(deviceId)"
        case .PeerStateChange(_, _, let userId, let deviceId, _, _): return "\(userId).\(deviceId)"
        case .ReceivedRemoteIce(_, _, let userId, let deviceId, _): return "\(userId).\(deviceId)"
        case .GeneratedLocalIce(_, _, let userId, let deviceId): return "\(userId).\(deviceId)"
        case .SentLocalIce(_, _, let userId, let deviceId, _): return "\(userId).\(deviceId)"
        }
    }
}

