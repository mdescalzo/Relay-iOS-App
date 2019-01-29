//
//  CallController.swift
//  Relay
//
//  Created by Greg Perkins on 1/28/19.
//  Copyright © 2019 Forsta, Inc. All rights reserved.
//

import Foundation
import RelayServiceKit

class ConferenceCallService: NSObject, FLCallMessageHandler {
    static let shared = ConferenceCallService();
    
    var conferenceCall: ConferenceCall?  // this can be a collection in the future

    public func receivedOffer(withThreadId threadId: String, callId: String, peerId: String, originatorId: String, sessionDescription: String) {
        // drop this if callId already exists
        // create new ConferenceCall of callId if it doesn't exist
        // trigger offers as needed for other partipants
    }

    public func receivedAcceptOffer(withThreadId threadId: String, callId: String, peerId: String, sessionDescription: String) {
        // drop this if ConferenceCall for callId doesn't exist
        // drop this if peer for that call doesn't exist
        // otherwise continue connection dance for this peer
    }
    
    public func receivedIceCandidates(withThreadId threadId: String, callId: String, peerId: String, iceCandidates: [Any]) {
        // ensure thread/call/peer are all good and drop if not
        // update connection stuff for this peer
    }
    
    public func receivedLeave(withThreadId threadId: String, callId: String, peerId: String) {
        // ensure thread/call/peer are all readl and drop if not
        // shut down this peer's connection, mark them as having left
        // if this is the only peer other than us, then shut down the whole call
    }
}
