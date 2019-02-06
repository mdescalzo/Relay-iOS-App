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

public enum CallError: Error {
    case providerReset
    case assertionError(description: String)
    case disconnected
    case externalError(underlyingError: Error)
    case timeout(description: String)
    case obsoleteCall(description: String)
    case other(description: String)
}

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

@objc class ConferenceCall: NSObject, PeerConnectionClientDelegate {
    let TAG = "[ConferenceCall]"
    
    var joinedDate: NSDate?

    let direction: ConferenceCallDirection
    let thread: TSThread;
    let callId: String;
    let originatorId: String;
    
    var delegates = [Weak<ConferenceCallDelegate>]()
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
            
            for delegate in delegates {
                delegate.value?.stateDidChange(call: self, state: state)
            }
        }
    }
    
    
    public required init(direction: ConferenceCallDirection, thread: TSThread, callId: String, originatorId: String) {
        self.direction = direction
        self.thread = thread
        self.callId = callId
        self.originatorId = originatorId
        self.state = (direction == .outgoing) ? .joined : .ringing
    }
    
    public func handleOffer(senderId: String, peerId: String, sessionDescription: String) {
        // skip it if we've already received this one
        if self.peerConnectionClients[peerId] != nil {
            Logger.debug("\(TAG) ignoring redundant offer for an existing peerId!: \(peerId)")
            return
        }
        
        // throw away any existing connections from this user
        for pId in (self.peerConnectionClients.filter { $0.value.userId == senderId }).keys {
            guard let pcc = self.peerConnectionClients[pId] else {
                continue;
            }
            self.peerConnectionClients.removeValue(forKey: pId)
            pcc.terminate()
        }

        // now get this new peer connection underway
        let newPcc = PeerConnectionClient(delegate: self, userId: senderId, peerId: peerId)
        self.peerConnectionClients[peerId] = newPcc
        newPcc.handleOffer(sessionDescription: sessionDescription)
        
        // and also kick off peer connections to other parties in the thread (if not already underway)
        self.inviteMissingParticipants()
    }
    
    func inviteMissingParticipants() {
        for userId in self.thread.participantIds {
            if (userId == TSAccountManager.localUID()! || self.peerConnectionClients.contains { $0.value.userId == userId }) {
                continue;
            }
            let newPeerId = NSUUID().uuidString.lowercased()
            let pcc = PeerConnectionClient(delegate: self, userId: userId, peerId: newPeerId)
            self.peerConnectionClients[newPeerId] = pcc
            pcc.sendOffer()
        }
    }
    
    func addRemoteIceCandidates(peerId: String, iceCandidates: [Any]) {
        guard let pcc = self.peerConnectionClients[peerId] else {
            Logger.debug("\(TAG) ignoring ice candidates for nonexistent peer \(peerId)")
            return
        }
        for candidate in iceCandidates {
            if let candidateDictiontary: Dictionary<String, Any> = candidate as? Dictionary<String, Any> {
                if let sdpMLineIndex: Int32 = candidateDictiontary["sdpMLineIndex"] as? Int32,
                    let sdpMid: String = candidateDictiontary["sdpMid"] as? String,
                    let sdp: String = candidateDictiontary["candidate"] as? String {
                    pcc.addRemoteIceCandidate(RTCIceCandidate(sdp: sdp, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid))
                } else {
                    Logger.debug("\(TAG) dropping bad ice candidate for peer \(peerId)")
                }
            }
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
    
    func addDelegate(delegate: ConferenceCallDelegate) {
        AssertIsOnMainThread(file: #function)
        delegates.append(Weak(value: delegate))
    }
    
    func removeDelegate(_ delegate: ConferenceCallDelegate) {
        AssertIsOnMainThread(file: #function)
        while let index = delegates.index(where: { $0.value === delegate }) {
            delegates.remove(at: index)
        }
    }
    
    // MARK: - PeerConnectionClientDelegate Implementation
    func owningCall() -> ConferenceCall {
        return self;
    }
    
    func peerConnectionFailed(strongPcc: PeerConnectionClient) {
        self.peerConnectionClients.removeValue(forKey: strongPcc.peerId)
        strongPcc.terminate()

        // depending on policy maybe give up on the entire call, or try connecting again to all the missing participants like this:
        self.inviteMissingParticipants();
        
        // tell ui delegate that stuff happened
    }
    
    func iceConnected(strongPcc: PeerConnectionClient) {
        Logger.debug("ice connected for peer \(strongPcc.peerId)")
        strongPcc.peerConnectedResolver.fulfill(())
    }
    
    func iceFailed(strongPcc: PeerConnectionClient) {
        Logger.debug("ice failed for peer \(strongPcc.peerId)")
    }
    
    func iceDisconnected(strongPcc: PeerConnectionClient) {
        Logger.debug("ice disconnected for peer \(strongPcc.peerId)")
    }
    
    func updatedRemoteVideoTrack(strongPcc: PeerConnectionClient, remoteVideoTrack: RTCVideoTrack) {
        Logger.debug("updated remote video track for peer \(strongPcc.peerId)")
    }
    
    func updatedLocalVideoCaptureSession(strongPcc: PeerConnectionClient, captureSession: AVCaptureSession?) {
        Logger.debug("updated local video capture for peer \(strongPcc.peerId)")
    }
}
