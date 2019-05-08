//
//  Copyright (c) 2017 Open Whisper Systems. All rights reserved.
//

import RelayServiceKit

@objc
public class NoopCallMessageHandler: NSObject, FLCallMessageHandler {
    public func receivedJoin(with thread: TSThread, senderId: String, senderDeviceId: UInt32, originatorId: String, callId: String) {
        owsFailDebug("\(self.logTag) in \(#function).")
    }
    
    public func receivedOffer(with thread: TSThread, senderId: String, senderDeviceId: UInt32, callId: String, peerId: String, sessionDescription: String) {
        owsFailDebug("\(self.logTag) in \(#function).")
    }
    
    public func receivedAcceptOffer(with thread: TSThread, callId: String, peerId: String, sessionDescription: String) {
        owsFailDebug("\(self.logTag) in \(#function).")
    }

    public func receivedSelfAcceptOffer(with thread: TSThread, callId: String, deviceId: UInt32) {
        owsFailDebug("\(self.logTag) in \(#function).")
    }

    public func receivedIceCandidates(with thread: TSThread, callId: String, peerId: String, iceCandidates: [Any]) {
        owsFailDebug("\(self.logTag) in \(#function).")
    }

    public func receivedLeave(with thread: TSThread, senderId: String, senderDeviceId: UInt32, callId: String) {
        owsFailDebug("\(self.logTag) in \(#function).")
    }
    
    public func receivedAnswer(with thread: TSThread, callId: String, peerId: String, sessionDescription: String) {
        owsFailDebug("\(self.logTag) in \(#function).")
    }
    
    public func receivedHangup(withCallId callId: String) {
        owsFailDebug("\(self.logTag) in \(#function).")
    }
    
    public func receivedIceUpdate(with thread: TSThread, sessionDescription sdp: String, sdpMid: String, sdpMLineIndex: Int32) {
        owsFailDebug("\(self.logTag) in \(#function).")
    }
    
    public func receivedOffer(with thread: TSThread, peerId: String, sessionDescription: String) {
        owsFailDebug("\(self.logTag) in \(#function).")
    }

    public func receivedOffer(_ offer: OWSSignalServiceProtosCallMessageOffer, from callerId: String) {
        owsFailDebug("\(self.logTag) in \(#function).")
    }

    public func receivedAnswer(_ answer: OWSSignalServiceProtosCallMessageAnswer, from callerId: String) {
        owsFailDebug("\(self.logTag) in \(#function).")
    }

    public func receivedIceUpdate(_ iceUpdate: OWSSignalServiceProtosCallMessageIceUpdate, from callerId: String) {
        owsFailDebug("\(self.logTag) in \(#function).")
    }

    public func receivedHangup(withThreadId threadId: String, callId: String) {
        owsFailDebug("\(self.logTag) in \(#function).")
    }

    public func receivedBusy(_ busy: OWSSignalServiceProtosCallMessageBusy, from callerId: String) {
        owsFailDebug("\(self.logTag) in \(#function).")
    }
}
