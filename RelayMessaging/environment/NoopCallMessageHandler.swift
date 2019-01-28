//
//  Copyright (c) 2017 Open Whisper Systems. All rights reserved.
//

import RelayServiceKit

@objc
public class NoopCallMessageHandler: NSObject, FLCallMessageHandler {
    public func receivedAnswer(withThreadId threadId: String, callId: String, peerId: String, sessionDescription: String) {
        owsFailDebug("\(self.logTag) in \(#function).")
    }
    
    public func receivedHangup(withCallId callId: String) {
        owsFailDebug("\(self.logTag) in \(#function).")
    }
    
    public func receivedIceUpdate(withThreadId threadId: String, sessionDescription sdp: String, sdpMid: String, sdpMLineIndex: Int32) {
        owsFailDebug("\(self.logTag) in \(#function).")
    }
    
    public func receivedOffer(withThreadId threadId: String, callId: String, originatorId: String, peerId: String, sessionDescription: String) {
        owsFailDebug("\(self.logTag) in \(#function).")
    }
    
    public func receivedOffer(withThreadId threadId: String, peerId: String, sessionDescription: String) {
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
