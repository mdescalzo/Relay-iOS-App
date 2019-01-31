//
//  ConferenceCall.swift
//  Relay
//
//  Created by Greg Perkins on 1/28/19.
//  Copyright © 2019 Forsta, Inc. All rights reserved.
//

import Foundation
import PromiseKit
import RelayServiceKit
import RelayMessaging
import UIKit

enum ConferenceCallDirection {
    case outgoing, incoming
}

enum ConferenceCallState {
    case ringing            // after receiving or sending an offer
    case rejected, joined   // after ringing
    case left               // after joined
    case failed             // after ringing or joined
}

protocol ConferenceCallDelegate: class {
    func stateDidChange(call: ConferenceCall, state: ConferenceCallState)
    func peerConnectionsNeedAttention(call: ConferenceCall, peerId: String)
}

class ConferenceCall: PeerConnectionClientObserver {
    let TAG = "[ConferenceCall]"
    
    var joinedDate: NSDate?

    let direction: ConferenceCallDirection
    let thread: TSThread;
    let callId: String;
    let originatorId: String;
    
    var observers = [Weak<ConferenceCallObserver>]()
    var peerConnectionClients = [String : PeerConnectionClient]() // indexed by peerId

    var callRecord: TSCall? {
        didSet {
            AssertIsOnMainThread(file: #function)
            assert(oldValue == nil)
            
            updateCallRecordType()
        }
    }
    
    var state: ConferenceCallState {
        didSet {
            AssertIsOnMainThread(file: #function)
            Logger.debug("\(TAG) state changed: \(oldValue) -> \(self.state) for call: \(self.callId)")
            
            // Update joinedDate
            if case .joined = self.state {
                // if it's the first time we've connected (not a reconnect)
                if joinedDate == nil {
                    joinedDate = NSDate()
                }
            }
            
            updateCallRecordType()
            
            for observer in observers {
                observer.value?.stateDidChange(call: self, state: state)
            }
        }
    }
    
    
    public required init(direction: ConferenceCallDirection, thread: TSThread, callId: String, originatorId: String) {
        self.direction = direction
        self.thread = thread
        self.callId = callId
        self.originatorId = originatorId
        if (direction == .outgoing) { self.state = .joined }
    }
    
    public func handleOffer(senderId: String, peerId: String, sessionDescription: String) {
        // skip it if we've already received this one
        if let pcc = self.peerConnectionClients[peerId] {
            Logger.debug("\(TAG) received ANOTHER offer for an existing peerId!: \(peerId)")
            return
        }
        
        // throw away any existing connections from this user
        for pId in self.peerConnectionClients.filter(where: { $0.userId == senderId }).keys() {
            let pcc = self.peerConnectionClients[pId]
            self.peerConnectionClients.removeValue(forKey: pId)
            pcc.uninit()
        }

        // now get this new peer connection underway
        let pcc = PeerConnectionClient(delegate: self, userId: senderId, peerId: peerId)
        self.peerConnectionClients[peerId] = pcc
        pcc.acceptOffer(sessionDescription)
        
        // and also kick off peer connections other parties in the thread (if not already underway)
        for userId in self.thread.participantIds {
            if (userId == senderId || userId == TSAccountManager.localUID()!
                || self.peerConnectionClients.contains { $0.userId == userId }) {
                continue;
            }
            let newPeerId = NSUUID().uuidString.lowercased()
            let pcc = PeerConnectionClient(delegate: self, userId: userId, peerId: newPeerId)
            self.peerConnectionClients[newPeerId] = pcc
            pcc.sendOffer()
        }
    }
        

    // MARK: - Class Helpers
    private func updateCallRecordType() {
        AssertIsOnMainThread(file: #function)
        
        guard let callRecord = self.callRecord else { return }
        
        if state == .joined &&
            callRecord.callType == RPRecentCallTypeOutgoingIncomplete {
            callRecord.updateCallType(RPRecentCallTypeOutgoing)
        }
        if state == .joined &&
            callRecord.callType == RPRecentCallTypeIncomingIncomplete {
            callRecord.updateCallType(RPRecentCallTypeIncoming)
        }
    }
    
    func addDelegate(observer: ConferenceCallDelegate) {
        AssertIsOnMainThread(file: #function)
        observers.append(Weak(value: observer))
    }
    
    func removeDelegate(_ observer: ConferenceCallDelegate) {
        AssertIsOnMainThread(file: #function)
        while let index = observers.index(where: { $0.value === observer }) {
            observers.remove(at: index)
        }
    }
    
    // MARK: - PeerConnectionClientDelegate Implementation
    func peerConnectionClientIceConnected(_ peerconnectionClient: PeerConnectionClient) {
        <#code#>
    }
    
    func peerConnectionClientIceFailed(_ peerconnectionClient: PeerConnectionClient) {
        <#code#>
    }
    
    func peerConnectionClientIceDisconnected(_ peerconnectionClient: PeerConnectionClient) {
        <#code#>
    }
    
    func peerConnectionClient(_ peerconnectionClient: PeerConnectionClient, addedLocalIceCandidate iceCandidate: RTCIceCandidate) {
        <#code#>
    }
    
    func peerConnectionClient(_ peerconnectionClient: PeerConnectionClient, received dataChannelMessage: OWSWebRTCProtosData) {
        <#code#>
    }
    
    func peerConnectionClient(_ peerconnectionClient: PeerConnectionClient, didUpdateLocalVideoCaptureSession captureSession: AVCaptureSession?) {
        <#code#>
    }
    
    func peerConnectionClient(_ peerconnectionClient: PeerConnectionClient, didUpdateRemoteVideoTrack videoTrack: RTCVideoTrack?) {
        <#code#>
    }
    
}
