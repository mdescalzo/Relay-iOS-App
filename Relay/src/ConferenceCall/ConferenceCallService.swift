//
//  CallController.swift
//  Relay
//
//  Created by Greg Perkins on 1/28/19.
//  Copyright © 2019 Forsta, Inc. All rights reserved.
//

import Foundation
import RelayServiceKit
import PromiseKit

protocol CallServiceObserver: class {
}

public class ConferenceCallService: NSObject, FLCallMessageHandler {
    static let shared = ConferenceCallService()
    let rtcQueue = DispatchQueue(label: "WebRTCDanceCard")
    var iceServers: Promise<[RTCIceServer]>
    var observers = [Weak<CallServiceObserver>]()

    override init() {
        iceServers = ConferenceCallService.getIceServers()
        super.init()
    }
    
    var conferenceCall: ConferenceCall?  // this can be a collection in the future, indexed by callId

    public func receivedOffer(with thread: TSThread, callId: String, senderId: String, peerId: String, originatorId: String, sessionDescription: String) {
        if conferenceCall != nil && conferenceCall?.callId != callId {
            Logger.debug("Ignoring call offer from/for a new call")
            return
        }
        if conferenceCall == nil {
            conferenceCall = ConferenceCall(direction: .incoming, thread: thread, callId: callId, originatorId: originatorId)
        }
        conferenceCall!.handleOffer(senderId: senderId, peerId: peerId, sessionDescription: sessionDescription)
    }

    public func receivedAcceptOffer(with thread: TSThread, callId: String, peerId: String, sessionDescription: String) {
        // drop this if ConferenceCall for callId doesn't exist
        // drop this if peer for that call doesn't exist
        // otherwise continue connection dance for this peer
    }
    
    public func receivedIceCandidates(with thread: TSThread, callId: String, peerId: String, iceCandidates: [Any]) {
        if conferenceCall == nil || (conferenceCall != nil && conferenceCall?.callId != callId) {
            Logger.debug("Ignoring ice candidates from/for an unknown call")
            return
        }
        conferenceCall?.addRemoteIceCandidates(peerId: peerId, iceCandidates: iceCandidates)
    }
    
    public func receivedLeave(with thread: TSThread, callId: String, peerId: String) {
        // ensure thread/call/peer are all readl and drop if not
        // shut down this peer's connection, mark them as having left
        // if this is the only peer other than us, then shut down the whole call
    }
    
    private static func getIceServers() -> Promise<[RTCIceServer]> {
        AssertIsOnMainThread(file: #function)
        
        return firstly {
            SignalApp.shared().accountManager.getTurnServerInfo()
            }.map { turnServerInfo -> [RTCIceServer] in
                Logger.debug("got turn server urls: \(turnServerInfo.urls)")
                
                return turnServerInfo.urls.map { url in
                        if url.hasPrefix("turn") {
                            // Only "turn:" servers require authentication. Don't include the credentials to other ICE servers
                            // as 1.) they aren't used, and 2.) the non-turn servers might not be under our control.
                            // e.g. we use a public fallback STUN server.
                            return RTCIceServer(urlStrings: [url], username: turnServerInfo.username, credential: turnServerInfo.password)
                        } else {
                            return RTCIceServer(urlStrings: [url])
                        }
                    } + [RTCIceServer(urlStrings: [fallbackIceServerUrl])]
            }.recover { (error: Error) -> Guarantee<[RTCIceServer]> in
                Logger.error("fetching ICE servers failed with error: \(error)")
                Logger.warn("using fallback ICE Server")
                
                return Guarantee.value([RTCIceServer(urlStrings: [fallbackIceServerUrl])])
        }
    }

    // MARK: - Observers
    
    // The observer-related methods should be invoked on the main thread.
    func addObserverAndSyncState(observer: CallServiceObserver) {
        AssertIsOnMainThread(file: #function)
        
        observers.append(Weak(value: observer))
    }
    
    // The observer-related methods should be invoked on the main thread.
    func removeObserver(_ observer: CallServiceObserver) {
        AssertIsOnMainThread(file: #function)
        
        while let index = observers.index(where: { $0.value === observer }) {
            observers.remove(at: index)
        }
    }
    
    // The observer-related methods should be invoked on the main thread.
    func removeAllObservers() {
        AssertIsOnMainThread(file: #function)
        
        observers = []
    }

}
