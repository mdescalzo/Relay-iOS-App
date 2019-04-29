//
//  Copyright (c) 2017 Open Whisper Systems. All rights reserved.
//

import RelayStorage

@objc
public class NoopCallMessageHandler: NSObject, FLCallMessageHandler {
    public func receivedJoin(with thread: FLIThread, senderId: String, senderDeviceId: UInt32, originatorId: String, callId: String) {
        owsFailDebug("\(self.logTag) in \(#function).")
    }
    
    public func receivedOffer(with thread: FLIThread, senderId: String, senderDeviceId: UInt32, callId: String, peerId: String, sessionDescription: String) {
        owsFailDebug("\(self.logTag) in \(#function).")
    }
    
    public func receivedAcceptOffer(with thread: FLIThread, callId: String, peerId: String, sessionDescription: String) {
        owsFailDebug("\(self.logTag) in \(#function).")
    }

    public func receivedSelfAcceptOffer(with thread: FLIThread, callId: String, deviceId: UInt32) {
        owsFailDebug("\(self.logTag) in \(#function).")
    }

    public func receivedIceCandidates(with thread: FLIThread, senderId: String, senderDeviceId: UInt32, callId: String, iceCandidates: [Any]) {
        owsFailDebug("\(self.logTag) in \(#function).")
    }

    public func receivedLeave(with thread: FLIThread, senderId: String, senderDeviceId: UInt32, callId: String) {
        owsFailDebug("\(self.logTag) in \(#function).")
    }
    
    public func receivedAnswer(with thread: FLIThread, callId: String, peerId: String, sessionDescription: String) {
        owsFailDebug("\(self.logTag) in \(#function).")
    }
    
    public func receivedHangup(withCallId callId: String) {
        owsFailDebug("\(self.logTag) in \(#function).")
    }
    
    public func receivedIceUpdate(with thread: FLIThread, sessionDescription sdp: String, sdpMid: String, sdpMLineIndex: Int32) {
        owsFailDebug("\(self.logTag) in \(#function).")
    }
    
    public func receivedOffer(with thread: FLIThread, peerId: String, sessionDescription: String) {
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
