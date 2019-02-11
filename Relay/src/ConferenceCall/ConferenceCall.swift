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


public enum CCIdentifiers: String {
    case mediaStream = "ARDAMS",
    videoTrack = "ARDAMSv0",
    audioTrack = "ARDAMSa0"
}

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
    case undefined          // (briefly) at creation
    case ringing            // after receiving offer
    case vibrating          // after some other device of mine has accepted that offer
    case rejected           // after ringing or vibrating
    case joined             // after ringing or vibrating (or having initiated a call)
    case leaving            // after joined
    case left               // after leaving or after last peer has left
    case failed             // after ringing/vibrating or joined
}

protocol ConferenceCallDelegate: class {
    func stateDidChange(call: ConferenceCall, state: ConferenceCallState)
    func peerConnectionDidConnect(peerId: String)
//    func rendererViewFor(peerId: String) -> RTCVideoRenderer?
//    func videoTrackDidUpdateFor(peerId: String)
}

@objc class ConferenceCall: NSObject, PeerConnectionClientDelegate, VideoCaptureSettingsDelegate {
    let TAG = "[ConferenceCall]"
    
    var joinedDate: NSDate?

    var direction: ConferenceCallDirection {
        get {
            if self.originatorId == TSAccountManager.localUID()! {
                return .outgoing
            } else {
                return .incoming
            }
        }
    }
    
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
    
    let audioActivity: AudioActivity
    
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
            
            if self.state == .joined && (oldValue == .ringing || oldValue == .vibrating) {
                answerPendingOffers()
            }
        }
    }
    
    
    // local connection stuff common to all peer connections
    var connectionConstraints: RTCMediaConstraints?
    var configuration: RTCConfiguration?
    
    var audioTrack: RTCAudioTrack?
    var audioConstraints: RTCMediaConstraints?
    
    var videoCaptureController: VideoCaptureController?

    var localVideoTrack: RTCVideoTrack? // RTCVideoTrack is fragile and prone to throwing exceptions and/or causing deadlock in its destructor.  Therefore we take great care with this property.
    
    
    public required init(thread: TSThread, callId: String, originatorId: String) {
        self.thread = thread
        self.callId = callId
        self.originatorId = originatorId
        self.state = .undefined
        super.init()
        self.state = (self.direction == .outgoing) ? .joined : .ringing
        
        var callType: RPRecentCallType
        switch self.direction {
        case .outgoing:
            callType = RPRecentCallTypeOutgoingIncomplete
        case .incoming:
            callType = RPRecentCallTypeIncoming
        }
        let cr = TSCall(timestamp: NSDate.ows_millisecondTimeStamp(), withCallNumber: self.callId, callType: callType, in: self.thread)
        cr.save()
        self.callRecord = cr
        
        self.audioActivity = AudioActivity(audioDescription: "\(TAG) with \(callId)")
    }
    
    // make sure all of the local audio/video local peer connection config is in place
    public func setUpLocalAV() -> Promise<Void> {
        if self.configuration != nil {
            return Promise<Void>.value(())
        }
        
        return firstly {
            ConferenceCallService.shared.iceServers
        }.then { (iceServers: [RTCIceServer]) -> Promise<Void> in
            if self.configuration != nil {
                return Promise<Void>.value(())
            }
            self.configuration = RTCConfiguration()
            self.configuration!.iceServers = iceServers
            self.configuration!.bundlePolicy = .maxBundle
            self.configuration!.rtcpMuxPolicy = .require
            
            let connectionConstraintsDict = ["DtlsSrtpKeyAgreement": "true"]
            self.connectionConstraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: connectionConstraintsDict)
            
            self.audioConstraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            
            self.createAudioSender()
            self.createVideoCaptureController()
            
            return Promise<Void>.value(())
        }
    }
    
    func answerPendingOffers() {
        for (_, pcc) in self.peerConnectionClients {
            pcc.readyToAnswerResolver.fulfill(())
        }
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
            Logger.info("GEP: throwing away existing peer \(pId) for user \(self.peerConnectionClients[pId]!.userId)")
            self.peerConnectionClients.removeValue(forKey: pId)
            pcc.terminatePeer()
        }

        // now get this new peer connection underway
        let newPcc = PeerConnectionClient(delegate: self, userId: senderId, peerId: peerId)
        self.peerConnectionClients[peerId] = newPcc
        newPcc.handleOffer(sessionDescription: sessionDescription)
        if (self.state == .joined) {
            newPcc.readyToAnswerResolver.fulfill(())
        }
        
        // and also kick off peer connections to other parties in the thread (if not already underway)
        self.inviteMissingParticipants()
    }
    
    public func handleAcceptOffer(peerId: String, sessionDescription: String) {
        // drop it if there's no such peer
        guard let pcc = self.peerConnectionClients[peerId] else {
            Logger.debug("\(TAG) ignoring AcceptOffer for nonexistent peer: \(peerId)")
            return
        }
        
        pcc.handleAcceptOffer(sessionDescription: sessionDescription)
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
    
    func handleRemoteIceCandidates(peerId: String, iceCandidates: [Any]) {
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
    
    func handlePeerLeave(peerId: String) {
        guard let pcc = self.peerConnectionClients[peerId] else {
            Logger.debug("\(TAG) ignoring leave for nonexistent peer \(peerId)")
            return
        }
        self.peerConnectionClients.removeValue(forKey: pcc.peerId)
        pcc.terminatePeer();

        // terminate the entire call if there are no other peers
        if self.peerConnectionClients.count == 0 {
            self.state = .left
        }
    }
    
    func leaveCall() {
        self.state = .leaving
    }
    
    func terminateCall() {
        for (_, pcc) in self.peerConnectionClients {
            pcc.terminatePeer()
        }
        self.peerConnectionClients.removeAll()
        self.state = .left
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
        strongPcc.terminatePeer()

        // depending on policy maybe give up on the entire call, or try connecting again to all the missing participants like this:
        // self.inviteMissingParticipants();
        
        // tell ui delegate that stuff happened
    }
    
    func iceConnected(strongPcc: PeerConnectionClient) {
        Logger.debug("ice connected for peer \(strongPcc.peerId)")
        
        self.state = .joined
        // TODO:  Make call that leads to UI adapter which will display new call UI here
        for delegate in delegates {
            delegate.value?.peerConnectionDidConnect(peerId: strongPcc.peerId)
        }

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
    
    // MARK: - Video
    
    fileprivate func createVideoCaptureController() {
        AssertIsOnMainThread(file: #function)
        Logger.debug("\(logTag) in \(#function)")
        assert(self.videoCaptureController == nil, "\(#function) should only be called once.")
        
        guard !Platform.isSimulator else {
            Logger.warn("\(logTag) Refusing to create local video track on simulator which has no capture device.")
            return
        }

        let videoSource = ConferenceCallService.rtcFactory.videoSource()
        
        let localVideoTrack = ConferenceCallService.rtcFactory.videoTrack(with: videoSource, trackId: CCIdentifiers.videoTrack.rawValue)
        self.localVideoTrack = localVideoTrack
        // Disable by default until call is connected.
        // FIXME - do we require mic permissions at this point?
        // if so maybe it would be better to not even add the track until the call is connected
        // instead of creating it and disabling it.
        localVideoTrack.isEnabled = true
        
        let capturer = RTCCameraVideoCapturer(delegate: videoSource)
        self.videoCaptureController = VideoCaptureController(capturer: capturer, settingsDelegate: self)
        
        // playing around... remove later
        self.videoCaptureController!.startCapture()
    }
    
    public func setCameraSource(isUsingFrontCamera: Bool) {
        AssertIsOnMainThread(file: #function)
        
        let strongSelf = self
        ConferenceCallService.shared.rtcQueue.async {
            guard let captureController = strongSelf.videoCaptureController else {
                owsFailDebug("\(self.logTag) in \(#function) captureController was unexpectedly nil")
                return
            }
            
            captureController.switchCamera(isUsingFrontCamera: isUsingFrontCamera)
        }
    }
    
    public func setLocalVideoEnabled(enabled: Bool) {
        AssertIsOnMainThread(file: #function)
        let strongSelf = self
        let completion = {
            let captureSession: AVCaptureSession? = {
                guard enabled else {
                    return nil
                }
                
                guard let captureController = strongSelf.videoCaptureController else {
                    owsFailDebug("\(self.logTag) in \(#function) videoCaptureController was unexpectedly nil")
                    return nil
                }
                
                return captureController.captureSession
            }()
        }
        
        ConferenceCallService.shared.rtcQueue.async {
            let strongSelf = self

            guard let videoCaptureController = strongSelf.videoCaptureController else {
                Logger.debug("\(strongSelf.logTag) \(#function) Ignoring obsolete event in terminated client")
                return
            }
            
            guard let localVideoTrack = strongSelf.localVideoTrack else {
                Logger.debug("\(strongSelf.logTag) \(#function) Ignoring obsolete event in terminated client")
                return
            }
            localVideoTrack.isEnabled = enabled
            
            if enabled {
                Logger.debug("\(strongSelf.logTag) in \(#function) starting video capture")
                videoCaptureController.startCapture()
            } else {
                Logger.debug("\(strongSelf.logTag) in \(#function) stopping video capture")
                videoCaptureController.stopCapture()
            }
            
            DispatchQueue.main.async(execute: completion)
        }
    }
    
    // MARK: VideoCaptureSettingsDelegate
    
    var videoWidth: Int32 {
        return 400
    }
    
    var videoHeight: Int32 {
        return 400
    }
    
    // MARK: - Audio
    
    fileprivate func createAudioSender() {
        AssertIsOnMainThread(file: #function)
        Logger.debug("\(logTag) in \(#function)")

        let audioSource = ConferenceCallService.rtcFactory.audioSource(with: self.audioConstraints)
        
        let audioTrack = ConferenceCallService.rtcFactory.audioTrack(with: audioSource, trackId: CCIdentifiers.audioTrack.rawValue)
        self.audioTrack = audioTrack
        
        // Disable by default until call is connected.
        // FIXME - do we require mic permissions at this point?
        // if so maybe it would be better to not even add the track until the call is connected
        // instead of creating it and disabling it.
        audioTrack.isEnabled = true
    }
    
    public func setAudioEnabled(enabled: Bool) {
        AssertIsOnMainThread(file: #function)
        let strongSelf = self
        ConferenceCallService.shared.rtcQueue.async {
            guard let audioTrack = strongSelf.audioTrack else {
                Logger.debug("\(strongSelf.logTag) \(#function) Ignoring obsolete event in terminated client")
                return
            }
            
            audioTrack.isEnabled = enabled
        }
    }

}



protocol VideoCaptureSettingsDelegate: class {
    var videoWidth: Int32 { get }
    var videoHeight: Int32 { get }
}

class VideoCaptureController {
    
    private let capturer: RTCCameraVideoCapturer
    private weak var settingsDelegate: VideoCaptureSettingsDelegate?
    private let serialQueue = DispatchQueue(label: "org.signal.videoCaptureController")
    private var isUsingFrontCamera: Bool = true
    
    public var captureSession: AVCaptureSession {
        return capturer.captureSession
    }
    
    public init(capturer: RTCCameraVideoCapturer, settingsDelegate: VideoCaptureSettingsDelegate) {
        self.capturer = capturer
        self.settingsDelegate = settingsDelegate
    }
    
    public func startCapture() {
        serialQueue.sync { [weak self] in
            guard let strongSelf = self else {
                return
            }
            
            strongSelf.startCaptureSync()
        }
    }
    
    public func stopCapture() {
        serialQueue.sync { [weak self] in
            guard let strongSelf = self else {
                return
            }
            
            strongSelf.capturer.stopCapture()
        }
    }
    
    public func switchCamera(isUsingFrontCamera: Bool) {
        serialQueue.sync { [weak self] in
            guard let strongSelf = self else {
                return
            }
            
            strongSelf.isUsingFrontCamera = isUsingFrontCamera
            strongSelf.startCaptureSync()
        }
    }
    
    private func assertIsOnSerialQueue() {
        if _isDebugAssertConfiguration(), #available(iOS 10.0, *) {
            assertOnQueue(serialQueue)
        }
    }
    
    private func startCaptureSync() {
        assertIsOnSerialQueue()
        
        let position: AVCaptureDevice.Position = isUsingFrontCamera ? .front : .back
        guard let device: AVCaptureDevice = self.device(position: position) else {
            owsFailDebug("unable to find captureDevice")
            return
        }
        
        guard let format: AVCaptureDevice.Format = self.format(device: device) else {
            owsFailDebug("unable to find captureDevice")
            return
        }
        
        let fps = self.framesPerSecond(format: format)
        capturer.startCapture(with: device, format: format, fps: fps)
    }
    
    private func device(position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let captureDevices = RTCCameraVideoCapturer.captureDevices()
        guard let device = (captureDevices.first { $0.position == position }) else {
            Logger.debug("unable to find desired position: \(position)")
            return captureDevices.first
        }
        
        return device
    }
    
    private func format(device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        let targetWidth = settingsDelegate?.videoWidth ?? 0
        let targetHeight = settingsDelegate?.videoHeight ?? 0
        
        var selectedFormat: AVCaptureDevice.Format?
        var currentDiff: Int32 = Int32.max
        
        for format in formats {
            let dimension = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let diff = abs(targetWidth - dimension.width) + abs(targetHeight - dimension.height)
            if diff < currentDiff {
                selectedFormat = format
                currentDiff = diff
            }
        }
        
        if _isDebugAssertConfiguration(), let selectedFormat = selectedFormat {
            let dimension = CMVideoFormatDescriptionGetDimensions(selectedFormat.formatDescription)
            Logger.debug("in \(#function) selected format width: \(dimension.width) height: \(dimension.height)")
        }
        
        assert(selectedFormat != nil)
        
        return selectedFormat
    }
    
    private func framesPerSecond(format: AVCaptureDevice.Format) -> Int {
        var maxFrameRate: Float64 = 0
        for range in format.videoSupportedFrameRateRanges {
            maxFrameRate = max(maxFrameRate, range.maxFrameRate)
        }
        
        return Int(maxFrameRate)
    }
}

