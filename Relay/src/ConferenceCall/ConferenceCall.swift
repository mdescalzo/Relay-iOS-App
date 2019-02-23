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


enum CCIdentifiers: String {
    case mediaStream = "ARDAMS",
    videoTrack = "ARDAMSv0",
    audioTrack = "ARDAMSa0"
}

enum CallError: Error {
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
}

protocol ConferenceCallDelegate: class {
    func stateDidChange(call: ConferenceCall, oldState: ConferenceCallState, newState: ConferenceCallState)
    func peerConnectionStateDidChange(pcc: PeerConnectionClient, oldState: PeerConnectionClientState, newState: PeerConnectionClientState)
    func peerConnectionDidUpdateRemoteVideoTrack(peerId: String, remoteVideoTrack: RTCVideoTrack)
    func peerConnectionDidUpdateRemoteAudioTrack(peerId: String, remoteAudioTrack: RTCAudioTrack)
    func didUpdateLocalVideoTrack(captureSession: AVCaptureSession?)
    func audioSourceDidChange(call: ConferenceCall, audioSource: AudioSource?)
}

extension ConferenceCallDelegate {
    
}

class CallAVPolicy {
    let startAudioMuted: Bool
    let allowAudioMuteToggle: Bool
    
    let startVideoMuted: Bool
    let allowVideoMuteToggle: Bool
    
    init(startAudioMuted: Bool, allowAudioMuteToggle: Bool, startVideoMuted: Bool, allowVideoMuteToggle: Bool) {
        self.startAudioMuted = startAudioMuted
        self.allowAudioMuteToggle = allowAudioMuteToggle
        self.startVideoMuted = startVideoMuted
        self.allowVideoMuteToggle = allowVideoMuteToggle
    }
}

@objc class ConferenceCall: NSObject, PeerConnectionClientDelegate, VideoCaptureSettingsDelegate {
    let TAG = "[ConferenceCall]"
    
    let policy: CallAVPolicy
    
    var joinedDate: NSDate?

    let direction: ConferenceCallDirection
    
    let thread: TSThread
    let callId: String
    lazy var callUUID = UUID(uuidString: self.callId)
    let originatorId: String
    
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
            if case .joined = self.state {
                // if it's the first time we've connected (not a reconnect)
                if joinedDate == nil {
                    joinedDate = NSDate()
                }
            }
            
            updateCallRecordType()
            
            notifyDelegates({ delegate in delegate.stateDidChange(call: self, oldState: oldValue, newState: self.state) })

            if self.state == .joined && (oldValue == .ringing || oldValue == .vibrating) {
                self.sendQueuedOffers()
            }
        }
    }
    
    var muted: Bool {
        didSet {
            for peer in self.peerConnectionClients.values {
                peer.audioSender?.track?.isEnabled = !self.muted
            }
        }
    }
    
    let audioActivity: AudioActivity

    // local connection stuff common to all peer connections
    var connectionConstraints: RTCMediaConstraints?
    var configuration: RTCConfiguration?
    
    var audioTrack: RTCAudioTrack?
    var audioConstraints: RTCMediaConstraints?
    
    var videoCaptureController: VideoCaptureController?

    var localVideoTrack: RTCVideoTrack? // RTCVideoTrack is fragile and prone to throwing exceptions and/or causing deadlock in its destructor.  Therefore we take great care with this property.

    
    required init(thread: TSThread, callId: String, originatorId: String, delegate: ConferenceCallDelegate?, policy: CallAVPolicy, direction: ConferenceCallDirection) {
        ConferenceCallEvents.add(.CallInit(callId: callId))
        self.policy = policy
        self.thread = thread
        self.callId = callId
        self.originatorId = originatorId
        self.direction = direction
        self.state = .undefined
        self.muted = policy.startAudioMuted
        self.audioActivity = AudioActivity(audioDescription: "\(TAG) with \(callId)")
        self.muted = policy.startAudioMuted

        super.init()
        if delegate != nil { self.addDelegate(delegate: delegate!) }

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
    }
    
    deinit {
        ConferenceCallEvents.add(.CallDeinit(callId: self.callId))
        Logger.info("\n\nLAST CALL:\n\(ConferenceCallEvents.lastCall)\n\n")
        Logger.info("\n\n\(ConferenceCallEvents.connectSpeeds)\n\n")
    }
    
    func cleanupBeforeDestruction() {
        self.removeAllDelegates()

        // audioTrack is a strong property because we need access to it to mute/unmute, but I was seeing it
        // become nil when it was only a weak property. So we retain it and manually nil the reference here, because
        // we are likely to crash if we retain any peer connection properties when the peerconnection is released
        
        localVideoTrack?.isEnabled = false

        audioTrack = nil
        localVideoTrack = nil
        videoCaptureController = nil
    }
    
    func sendQueuedOffers() {
        for pcc in self.peerConnectionClients.values {
            pcc.readyToSendOfferResolver.fulfill(())
        }
    }
    
    func locatePCC(_ userId: String, _ deviceId: UInt32) -> PeerConnectionClient? {
        for peerId in (self.peerConnectionClients.filter { $0.value.userId == userId && $0.value.deviceId == deviceId }).keys {
            guard let pcc = self.peerConnectionClients[peerId] else {
                continue
            }
            return pcc
        }
        return nil
    }
    
    func setUpLocalAV() -> Promise<Void> {
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
    
    func handleJoin(userId: String, deviceId: UInt32) {
        let pcc = locatePCC(userId, deviceId)
        pcc?.state = .discarded

        let newPeerId = NSUUID().uuidString.lowercased()
        let newPcc = PeerConnectionClient(delegate: self, userId: userId, deviceId: deviceId, peerId: newPeerId, callId: self.callId)
        self.peerConnectionClients[newPeerId] = newPcc

        newPcc.queueOffer()
    }
    
    public func handleOffer(userId: String, deviceId: UInt32, peerId: String, sessionDescription: String) {
        let pcc = locatePCC(userId, deviceId)
        pcc?.state = .discarded

        let newPcc = PeerConnectionClient(delegate: self, userId: userId, deviceId: deviceId, peerId: peerId, callId: self.callId)
        self.peerConnectionClients[peerId] = newPcc
        newPcc.handleOffer(sessionDescription: sessionDescription)
        
        return
    }
    
    public func handleAcceptOffer(peerId: String, sessionDescription: String) {
        guard let pcc = self.peerConnectionClients[peerId] else {
            Logger.debug("\(TAG) ignoring AcceptOffer for nonexistent peer: \(peerId)")
            return
        }
        
        pcc.handleAcceptOffer(sessionDescription: sessionDescription)
    }
    
    public func handleSelfAcceptOffer(deviceId: UInt32) {
        Logger.info("GEP: handling accept-offer from self, device id \(deviceId)")
        if self.state == .ringing {
            self.state = .vibrating
        }
    }
    
    func handleRemoteIceCandidates(userId: String, deviceId: UInt32, iceCandidates: [Any]) {
        let pcc = locatePCC(userId, deviceId)
        pcc?.addRemoteIceCandidates(iceCandidates)
    }
    
    func handleLeave(userId: String, deviceId: UInt32) {
        let pcc = locatePCC(userId, deviceId)
        pcc?.state = .peerLeft
    }

    func rejectCall() {
        self.state = .rejected
        self.leaveCall()
    }
    
    func joinCall() {
        guard let messageSender = Environment.current()?.messageSender else {
            Logger.info("can't get messageSender")
            return
        }
        
        let members = self.thread.participantIds
        let allTheData = [
            "version": ConferenceCallProtocolLevel,
            "originator" : self.originatorId,
            "callId" : self.callId,
            "members" : members
            ] as NSMutableDictionary
        let message = OutgoingControlMessage(thread: self.thread, controlType: FLControlMessageCallJoinKey, moreData: allTheData)
        messageSender.sendPromise(message: message, recipientIds: members).done({ _ in
            ConferenceCallEvents.add(.SentCallJoin(callId: self.callId))
            self.state = .joined // will send queued offers
        }).retainUntilComplete()
    }
    
    func leaveCall() {
        guard let messageSender = Environment.current()?.messageSender else {
            Logger.info("can't get messageSender")
            return
        }
        
        self.state = .leaving
        
        for pcc in self.peerConnectionClients.values {
            pcc.state = .leftPeer
        }

        let members = self.thread.participantIds
        
        let allTheData = [ "version": ConferenceCallProtocolLevel, "callId" : self.callId ] as NSMutableDictionary
        
        let message = OutgoingControlMessage(thread: self.thread, controlType: FLControlMessageCallLeaveKey, moreData: allTheData)
        messageSender.sendPromise(message: message, recipientIds: members).done({ _ in
            ConferenceCallEvents.add(.SentCallLeave(callId: self.callId))
            self.state = .left
        }).retainUntilComplete()
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
    
    func removeAllDelegates() {
        AssertIsOnMainThread(file: #function)
        delegates = []
    }

    func notifyDelegates(_ todo: (_ theDelegate: ConferenceCallDelegate) -> Void) {
        for delegate in delegates {
            if delegate.value != nil {
                todo(delegate.value!)
            }
        }
    }
    
    // MARK: - PeerConnectionClientDelegate Implementation

    func stateDidChange(pcc: PeerConnectionClient, oldState: PeerConnectionClientState, newState: PeerConnectionClientState) {
        notifyDelegates({ delegate in delegate.peerConnectionStateDidChange(pcc: pcc, oldState: oldState, newState: newState) })
        
        if newState.isTerminal {
            Logger.debug("GEP: blowing away terminal peer \(pcc.peerId) in call \(pcc.callId)")
            self.peerConnectionClients.removeValue(forKey: pcc.peerId)
            pcc.cleanupBeforeDestruction()
        }
    }
    
    func owningCall() -> ConferenceCall {
        return self
    }
    
    func updatedRemoteVideoTrack(strongPcc: PeerConnectionClient, remoteVideoTrack: RTCVideoTrack) {
        Logger.debug("updated remote video track for peer \(strongPcc.peerId)")
        notifyDelegates({ delegate in delegate.peerConnectionDidUpdateRemoteVideoTrack(peerId: strongPcc.peerId, remoteVideoTrack: remoteVideoTrack)})
    }
    
    func updatedRemoteAudioTrack(strongPcc: PeerConnectionClient, remoteAudioTrack: RTCAudioTrack) {
        Logger.debug("updated remote audio track for peer \(strongPcc.peerId)")
        notifyDelegates({ delegate in delegate.peerConnectionDidUpdateRemoteAudioTrack(peerId: strongPcc.peerId, remoteAudioTrack: remoteAudioTrack)})
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
        self.setLocalVideoEnabled(enabled: !self.policy.startVideoMuted)
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
            guard enabled else {
                return
            }
            
            guard let captureController = strongSelf.videoCaptureController else {
                owsFailDebug("\(self.logTag) in \(#function) videoCaptureController was unexpectedly nil")
                return
            }
            
            let captureSession = captureController.captureSession
            strongSelf.notifyDelegates({ delegate in delegate.didUpdateLocalVideoTrack(captureSession: captureSession) })
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
    
    var audioSource: AudioSource? = nil {
        didSet {
            AssertIsOnMainThread()
            Logger.debug("audioSource changed: \(String(describing: oldValue)) -> \(String(describing: audioSource))")
            
            self.notifyDelegates({ delegate in delegate.audioSourceDidChange(call: self, audioSource: audioSource) })
        }
    }
    
    fileprivate func createAudioSender() {
        AssertIsOnMainThread(file: #function)
        Logger.debug("\(logTag) in \(#function)")

        let audioSource = ConferenceCallService.rtcFactory.audioSource(with: self.audioConstraints)
        
        let audioTrack = ConferenceCallService.rtcFactory.audioTrack(with: audioSource, trackId: CCIdentifiers.audioTrack.rawValue)
        self.audioTrack = audioTrack
        
        audioTrack.isEnabled = !self.policy.startAudioMuted
    }
    
    public func setAudioEnabled(enabled: Bool) {
        AssertIsOnMainThread(file: #function)
        if !self.policy.allowAudioMuteToggle { return }
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

