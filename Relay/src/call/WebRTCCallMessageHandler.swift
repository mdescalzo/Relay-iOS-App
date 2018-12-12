//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

import Foundation
import RelayServiceKit
import RelayMessaging

@objc(OWSWebRTCCallMessageHandler)
public class WebRTCCallMessageHandler: NSObject, OWSCallMessageHandler {

    // MARK - Properties

    let TAG = "[WebRTCCallMessageHandler]"

    // MARK: Dependencies

    let accountManager: AccountManager
    let callService: CallService
    let messageSender: MessageSender

    // MARK: Initializers

    @objc public required init(accountManager: AccountManager, callService: CallService, messageSender: MessageSender) {
        self.accountManager = accountManager
        self.callService = callService
        self.messageSender = messageSender

        super.init()

        SwiftSingletons.register(self)
    }

    // MARK: - Call Handlers
    public func receivedOffer(withThreadId threadId: String, callId: String, originatorId: String, peerId: String, sessionDescription: String) {
        SwiftAssertIsOnMainThread(#function)
        
        let thread = TSThread.getOrCreateThread(withId: threadId)
        
        self.callService.handleReceivedOffer(thread: thread, callId: callId, originatorId: originatorId, peerId: peerId, sessionDescription: sessionDescription)
    }
    
    public func receivedAnswer(withThreadId threadId: String, callId: String, peerId: String, sessionDescription: String) {
        SwiftAssertIsOnMainThread(#function)
        
        let thread = TSThread.getOrCreateThread(withId: threadId)
        self.callService.handleReceivedAnswer(thread: thread, peerId: peerId, sessionDescription: sessionDescription)
    }
    
    public func receivedIceUpdate(withThreadId threadId: String, sessionDescription sdp: String, sdpMid: String, sdpMLineIndex: Int32) {
        SwiftAssertIsOnMainThread(#function)

        let thread = TSThread.getOrCreateThread(withId: threadId)

        if let peerId = callService.call?.peerId {
            self.callService.handleRemoteAddedIceCandidate(thread: thread, peerId: peerId, sdp: sdp, lineIndex: sdpMLineIndex, mid: sdpMid)
        }
    }
    
    public func receivedHangup(withThreadId threadId: String, callId: String) {
        SwiftAssertIsOnMainThread(#function)

        let thread = TSThread.getOrCreateThread(withId: threadId)
        self.callService.handleRemoteHangup(thread: thread, callId: callId)
    }
    
//    public func receivedHangup(_ hangup: OWSSignalServiceProtosCallMessageHangup, from callerId: String) {
//        SwiftAssertIsOnMainThread(#function)
//        guard hangup.hasId() else {
//            owsFail("no callId in \(#function)")
//            return
//        }
//
//        let thread = TSThread.getOrCreateThread(withId: callerId)
//        self.callService.handleRemoteHangup(thread: thread, peerId: "\(hangup.id)")
//    }

    public func receivedBusy(_ busy: OWSSignalServiceProtosCallMessageBusy, from callerId: String) {
        SwiftAssertIsOnMainThread(#function)
        guard busy.hasId() else {
            owsFail("no callId in \(#function)")
            return
        }

        let thread = TSThread.getOrCreateThread(withId: callerId)
        self.callService.handleRemoteBusy(thread: thread, peerId: "\(busy.id)")
    }

}
