//
//  ConferenceCallCollectionViewController.swift
//  CallUITestBed
//
//  Created by Mark Descalzo on 1/31/19.
//  Copyright © 2019 Ringneck Software, LLC. All rights reserved.
//

import UIKit
import CoreData
//import PromiseKit

private let reuseIdentifier = "peerCell"

class ConferenceCallViewController: UIViewController, ConferenceCallServiceDelegate , ConferenceCallDelegate, CallAudioServiceDelegate {
    
    var mainPeerId: String?
    
    var secondaryPeerIds = [String]()
    
    var peerUIElements = [ String : PeerUIElements ]()
    var hasDismissed = false
    
    lazy var callKitService = {
        return CallUIService.shared
    }()
    
    @IBOutlet var stackContainerView: UIStackView!
    
    @IBOutlet weak var mainPeerAVView: RemoteVideoView!
    @IBOutlet weak var mainPeerAvatarView: UIImageView!
    @IBOutlet weak var mainPeerStatusIndicator: UIView!
    @IBOutlet weak var mainPeerStatusContainer: UIView!
    @IBOutlet weak var mainPeerStatusLabel: UILabel!
    @IBOutlet weak var localAVView: RTCCameraPreviewView!
    
    @IBOutlet weak var infoContainerView: UIView!
    @IBOutlet weak var infoLabel: UILabel!
    @IBOutlet weak var collectionView: UICollectionView!
    @IBOutlet weak var collectionViewHeightConstraint: NSLayoutConstraint!
    @IBOutlet weak var controlsContainerView: UIView!
    @IBOutlet weak var muteButton: UIButton!
    @IBOutlet weak var videoToggleButton: UIButton!
    @IBOutlet weak var audioOutButton: UIButton!
    @IBOutlet weak var leaveCallButton: UIButton!
    
    lazy var allAudioSources = Set(self.callKitService.audioService.availableInputs)
    
    var call: ConferenceCall?
    
    func configure(call: ConferenceCall) {
        self.call = call
    }
    
    func hasLocalVideo() -> Bool {
        return (self.call?.localVideoTrack != nil)
    }
    
    override func loadView() {
        super.loadView()
        self.mainPeerStatusIndicator.layer.cornerRadius = self.mainPeerStatusIndicator.frame.size.width/2
        self.callKitService.audioService.delegate = self
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Uncomment the following line to preserve selection between presentations
        // self.clearsSelectionOnViewWillAppear = false
        
        // Register cell classes - only use if not using Storyboard
        //        self.collectionView!.register(PeerViewCell.self, forCellWithReuseIdentifier: reuseIdentifier)
        
        // Do any additional setup after loading the view.
        guard self.call != nil else {
            owsFailDebug("\(self.logTag): CallViewController loaded with nil call object!")
            self.dismissImmediately(completion: nil)
            return
        }
        
        // Collect Peers and connect to UI elements
        for peer in (self.call?.peerConnectionClients.values)! {
            if self.call?.originatorId == peer.userId {
                self.setPeerIdAsMain(peer.peerId)
            } else {
                self.addSecondaryPeerId(peer.peerId)
            }
        }
        if self.mainPeerId == nil {
            if let peer = self.call?.peerConnectionClients.values.first {
                self.setPeerIdAsMain(peer.peerId)
                self.removeSecondaryPeerId(peer.peerId)
            }
        }
        
        self.updatePeerViewHeight()
        
        // Peer view setup
        if let layout = self.collectionView?.collectionViewLayout as? PeerViewsLayout {
            layout.delegate = self
        }
        
        // Gesture handlers
        let doubleTapGestureRecognizer = UITapGestureRecognizer(target: self,
                                                                action: #selector(ConferenceCallViewController.didDoubleTapCollectionView(gesture:)))
        doubleTapGestureRecognizer.numberOfTapsRequired = 2
        self.collectionView.addGestureRecognizer(doubleTapGestureRecognizer)
        
        let longPressGestureRecognizer = UILongPressGestureRecognizer(target: self,
                                                                      action: #selector(ConferenceCallViewController.didLongPressCollectionView(gesture:)))
        self.collectionView.addGestureRecognizer(longPressGestureRecognizer)
        
        self.infoLabel.text = call?.thread.displayName()
        
        // Local AV
        if let captureSession = self.call?.videoCaptureController?.captureSession {
            self.localAVView.captureSession = captureSession
            self.localAVView.isHidden = false
        } else {
            self.localAVView.isHidden = true
        }
        
        // Start listening to the call
        self.call!.addDelegate(delegate: self)
        
        // UI Built, config it
        self.updateUIForCallPolicy()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        if self.call?.state == .ringing || self.call?.state == .vibrating {
            self.call?.acceptCall()
        }
    }
    
    // MARK: - Audio Source
    var hasAlternateAudioSources: Bool {
        Logger.info("available audio sources: \(allAudioSources)")
        // internal mic and speakerphone will be the first two, any more than one indicates e.g. an attached bluetooth device.
        // TODO is this sufficient? Are their devices w/ bluetooth but no external speaker? e.g. ipod?
        return allAudioSources.count > 2
    }
    
    var appropriateAudioSources: Set<AudioSource> {
        if self.hasLocalVideo() {
            let appropriateForVideo = allAudioSources.filter { audioSource in
                if audioSource.isBuiltInSpeaker {
                    return true
                } else {
                    guard let portDescription = audioSource.portDescription else {
                        owsFailDebug("Only built in speaker should be lacking a port description.")
                        return false
                    }
                    
                    // Don't use receiver when video is enabled. Only bluetooth or speaker
                    return portDescription.portType != AVAudioSessionPortBuiltInMic
                }
            }
            return Set(appropriateForVideo)
        } else {
            return allAudioSources
        }
    }
    
    func presentAudioSourcePicker() {
        AssertIsOnMainThread()
        
        let actionSheetController = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        
        let dismissAction = UIAlertAction(title: CommonStrings.dismissButton, style: .cancel, handler: nil)
        actionSheetController.addAction(dismissAction)
        
        let currentAudioSource = self.callKitService.audioService.currentAudioSource(self.call!)
        for audioSource in self.appropriateAudioSources {
            let routeAudioAction = UIAlertAction(title: audioSource.localizedName, style: .default) { _ in
                self.callKitService.setAudioSource(call: self.call!, audioSource: audioSource)
            }
            
            // HACK: private API to create checkmark for active audio source.
            routeAudioAction.setValue(currentAudioSource == audioSource, forKey: "checked")
            
            // TODO: pick some icons. Leaving out for MVP
            // HACK: private API to add image to actionsheet
            // routeAudioAction.setValue(audioSource.image, forKey: "image")
            actionSheetController.addAction(routeAudioAction)
        }
        
        // Note: It's critical that we present from this view and
        // not the "frontmost view controller" since this view may
        // reside on a separate window.
        self.present(actionSheetController, animated: true)
    }
    
    // MARK: - CallAudioServiceDelegate methods
    func callAudioService(_ callAudioService: CallAudioService, didUpdateIsSpeakerphoneEnabled isEnabled: Bool) {
        // TODO: Fix bug in setting speaker as audio source when other devices exist
    }
    
    func callAudioServiceDidChangeAudioSession(_ callAudioService: CallAudioService) {
        let availableInputs = callAudioService.availableInputs
        self.allAudioSources.formUnion(availableInputs)
    }
    
    // MARK: - Helpers
    private func updatePeerUIElement(_ peerId: String, animated: Bool) {
        guard let peerClient = self.call?.peerConnectionClients[peerId] else {
            // Invalid Peer for this call, remove it
            self.removePeerFromView(peerId)
            return
        }
        
        guard let uiElements = self.peerUIElements[peerId] else {
            // No peer element references available to update
            return
        }
        
        let visibilityBlock: () -> Void = {
            uiElements.avView?.isHidden = (peerClient.state == .connected ? false : true)
            uiElements.statusLabel?.isHidden = (peerClient.state == .connected ? true : false )
            uiElements.statusIndicator?.isHidden = (peerClient.state == .connected ? true : false )
        }
        
        let messagingBlock: () -> Void = {
            var message: String
            var color: UIColor
            
            switch peerClient.state {
                
            case .undefined:
                do {
                    message = ""
                    color = UIColor.clear
                }
            case .awaitingLocalJoin:
                do {
                    message = ""
                    color = UIColor.cyan
                }
            case .sendingAcceptOffer:
                do {
                    message = "Accepting invitation"
                    color = UIColor.yellow
                }
            case .sentAcceptOffer:
                do {
                    message = "Accepted invitation"
                    color = UIColor.blue
                }
            case .sendingOffer:
                do {
                    message = "Sending invitation"
                    color = UIColor.orange
                }
            case .readyToReceiveAcceptOffer:
                do {
                    message = "Awaiting response"
                    color = UIColor.brown
                }
            case .receivedAcceptOffer:
                do {
                    message = "Response received"
                    color = UIColor.yellow
                }
            case .connected:
                do {
                    message = "Connected!"
                    color = UIColor.green
                }
            case .peerLeft:
                do {
                    message = "Participant left"
                    color = UIColor.gray
                }
            case .leftPeer:
                do {
                    message = "Left call"
                    color = UIColor.gray
                }
            case .discarded:
                do {
                    message = ""
                    color = UIColor.clear
                }
            case .disconnected:
                do {
                    message = "Disconnected"
                    color = UIColor.darkGray
                }
            case .failed:
                do {
                    message = "Connection failed"
                    color = UIColor.red
                }
            }
            uiElements.statusIndicator?.backgroundColor = color
            uiElements.statusLabel?.text = message
        }
        
        if animated {
            UIView.animate(withDuration: 0.25, animations: {
                messagingBlock()
            }) { (complete) in
                UIView.animate(withDuration: 0.25) {
                    visibilityBlock()
                }
            }
        } else {
            messagingBlock()
            visibilityBlock()
        }
    }
    
    private func updateUIForCallPolicy() {
        guard let policy = self.call?.policy else {
            Logger.debug("\(self.logTag) No call policy to enforce")
            return
        }
        
        self.muteButton.isEnabled = policy.allowAudioMuteToggle
        self.muteButton.alpha = (policy.allowAudioMuteToggle ? 1.0 : 0.75)
        
        self.videoToggleButton.isEnabled = policy.allowVideoMuteToggle
        self.muteButton.alpha = (policy.allowVideoMuteToggle ? 1.0 : 0.75)
        
        self.muteButton.isSelected = policy.startAudioMuted
        self.callKitService.setIsMuted(call: self.call!, isMuted: self.muteButton.isSelected)
        
        self.videoToggleButton.isSelected = !policy.startVideoMuted
        if !self.hasAlternateAudioSources {
            self.audioOutButton.isSelected = !policy.startVideoMuted
            self.callKitService.audioService.requestSpeakerphone(isEnabled: self.audioOutButton.isSelected)
        }
        self.call?.setLocalVideoEnabled(enabled: self.videoToggleButton.isSelected)
    }
    
    private func setPeerIdAsMain(_ peerId: String) {
        // Make sure we're actually making a change
        guard self.mainPeerId != peerId else {
            return
        }
        
        let mainUserUI = PeerUIElements()
        mainUserUI.statusIndicator = self.mainPeerStatusIndicator
        mainUserUI.statusView = self.mainPeerStatusContainer
        mainUserUI.statusLabel = self.mainPeerStatusLabel
        mainUserUI.avatarView = self.mainPeerAvatarView
        mainUserUI.avView = self.mainPeerAVView
        self.peerUIElements[peerId] = mainUserUI
        
        
        // clean up if we are replacing a prior peer
        if self.mainPeerId != nil {
            if let oldPeer = self.call?.peerConnectionClients[self.mainPeerId!] {
                oldPeer.remoteVideoTrack?.remove(self.mainPeerAVView)
            }
        }
        
        // Setup the video view
        if let newPeer = self.call?.peerConnectionClients[peerId] {
            newPeer.remoteVideoTrack?.add(self.mainPeerAVView)
            
            if let avatarImage = FLContactsManager.shared.avatarImageRecipientId(newPeer.userId) {
                self.mainPeerAvatarView.image = avatarImage
            } else {
                self.mainPeerAvatarView.image = UIImage(named: "actionsheet_contact")
            }
        } else {
            self.mainPeerAvatarView.image = UIImage(named: "actionsheet_contact")
        }
        self.mainPeerId = peerId
        
        self.updatePeerUIElement(peerId, animated: true)
    }
    
    private func addSecondaryPeerId(_ peerId: String) {
        guard !self.secondaryPeerIds.contains(peerId) else {
            // Peer is already there. Don't add it twice
            return
        }
        
        self.collectionView.performBatchUpdates({
            let index = self.secondaryPeerIds.count
            self.secondaryPeerIds.insert(peerId, at: index)
            self.collectionView.insertItems(at: [IndexPath(item: index, section: 0)])
        }, completion: { complete in
            self.updatePeerUIElement(peerId, animated: true)
        })
    }
    
    private func removeSecondaryPeerId(_ peerId: String) {
        guard self.secondaryPeerIds.contains(peerId) else {
            // User isn't there to remove.  Bail.
            return
        }
        
        // Disconnect the remoteVideoTrack
        if let peer = self.call?.peerConnectionClients[peerId] {
            if let avView = self.peerUIElements[peerId]?.avView {
                if let remoteVideoTrack = peer.remoteVideoTrack {
                    remoteVideoTrack.remove(avView)
                }
            }
        }
        
        // Update the collection view
        self.collectionView.performBatchUpdates({
            if let index = self.secondaryPeerIds.firstIndex(of: peerId) {
                self.secondaryPeerIds.remove(at: index)
                self.collectionView.deleteItems(at: [IndexPath(item: index, section: 0)])
            }
        }, completion: { complete in
            self.updatePeerUIElement(peerId, animated: true)
            self.peerUIElements[peerId] = nil
        })
    }
    
    private func removePeerFromView(_ peerId: String) {
        if self.mainPeerId == peerId {
            // Tear down the main peer
            if let peer = self.call?.peerConnectionClients[peerId] {
                if let avView = self.peerUIElements[peerId]?.avView {
                    if let remoteVideoTrack = peer.remoteVideoTrack {
                        remoteVideoTrack.remove(avView)
                    }
                }
            }
            self.mainPeerId = nil
            self.peerUIElements[peerId] = nil
    
            // get a new main peer
            if let peer = self.call?.peerConnectionClients.values.first {
                self.setPeerIdAsMain(peer.peerId)
                self.removeSecondaryPeerId(peer.peerId)
            }
        } else {
            self.removeSecondaryPeerId(peerId)
        }
    }
    
    private func updatePeerAVElements(peerId: String, message: String, hideAV: Bool, indicatorColor: UIColor, hideIndicator: Bool) {
        if let userElements = self.peerUIElements[peerId] {
            let duration = 0.25
            
            UIView.animate(withDuration: duration, animations: {
                userElements.statusLabel?.text = message
                userElements.avView?.isHidden = hideAV
                userElements.statusIndicator?.backgroundColor = indicatorColor
            }) { (complete) in
                self.updatePeerUIElement(peerId, animated: true)
            }
        }
    }
    
    
    private func updatePeerViewHeight() {
        let oldValue = self.collectionViewHeightConstraint.constant
        
        var newValue: CGFloat
        
        if self.secondaryPeerIds.count > 0 {
            newValue = UIScreen.main.bounds.width/4
        } else {
            newValue = 0
        }
        
        if oldValue != newValue {
            UIView.animate(withDuration: 0.1) {
                self.collectionViewHeightConstraint.constant = newValue
            }
        }
    }
    
    internal func dismissIfPossible(shouldDelay: Bool, completion: (() -> Void)? = nil) {
        // callUIAdapter!.audioService.delegate = nil
        
        if hasDismissed {
            // Don't dismiss twice.
            return
        } else if shouldDelay {
            hasDismissed = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let strongSelf = self else { return }
                strongSelf.dismissImmediately(completion: completion)
            }
        } else {
            hasDismissed = true
            dismissImmediately(completion: completion)
        }
    }
    
    internal func dismissImmediately(completion: (() -> Void)?) {
        OWSWindowManager.shared().endCall(self)
        completion?()
    }
    
    // MARK: - Action handlers
    @IBAction func didTapExitButton(_ sender: UIButton) {
        // TODO: Validate ending call if one is active
        if self.call != nil {
            self.callKitService.localHangupCall(self.call!)
            self.call = nil
        }
        self.dismissIfPossible(shouldDelay: false)
    }
    
    @objc func didDoubleTapCollectionView(gesture: UITapGestureRecognizer) {
        let pointInCollectionView = gesture.location(in: self.collectionView)
        if let selectedIndexPath = self.collectionView.indexPathForItem(at: pointInCollectionView) {
            
            // Swap this peer for the main Peer
            let thisPeerId = self.secondaryPeerIds[selectedIndexPath.item]
            self.removeSecondaryPeerId(thisPeerId)
            if self.mainPeerId != nil {
                self.addSecondaryPeerId(self.mainPeerId!)
            }
            self.setPeerIdAsMain(thisPeerId)
        }
    }
    
    @objc func didLongPressCollectionView(gesture: UITapGestureRecognizer) {
        let pointInCollectionView = gesture.location(in: self.collectionView)
        if let selectedIndexPath = self.collectionView.indexPathForItem(at: pointInCollectionView) {
            let selectedCell = self.collectionView.cellForItem(at: selectedIndexPath) as! PeerViewCell
            selectedCell.avView.isHidden = !selectedCell.avView.isHidden
        }
    }
    
    @IBAction func didTapMuteButton(_ sender: UIButton) {
        Logger.info("\(self.logTag) called \(#function)")
        
        self.muteButton.isSelected = !self.muteButton.isSelected
        
        guard let call = self.call else {
            Logger.debug("\(self.logTag): Dropping mute set for obsolete call.")
            return
        }
        
        self.callKitService.setIsMuted(call: call, isMuted: self.muteButton.isSelected)
    }
    
    @IBAction func didTapVideoToggleButton(_ sender: UIButton) {
        Logger.info("\(self.logTag) called \(#function)")
        self.videoToggleButton.isSelected = !self.videoToggleButton.isSelected
        
        self.call?.setLocalVideoEnabled(enabled: self.videoToggleButton.isSelected)
    }
    
    @IBAction func didTapAudioButton(_ sender: UIButton) {
        Logger.info("\(self.logTag) called \(#function)")
        
        if self.hasAlternateAudioSources {
            presentAudioSourcePicker()
        } else {
            // Toggle speakerphone
            sender.isSelected = !sender.isSelected
            self.callKitService.audioService.requestSpeakerphone(isEnabled: sender.isSelected)
        }
    }
    
    @IBAction func didTapCallButton(_ sender: UIButton) {
        // TODO:  Create visual reference for leaving the call, ie spinner/disable button
        
        guard self.call != nil else {
            self.leaveCallButton.isEnabled = false
            self.leaveCallButton.alpha = 0.5
            self.dismissIfPossible(shouldDelay: true)
            return
        }
        
        if sender.isSelected {
            // restart the call
            self.call!.inviteMissingParticipants()
        } else {
            // end the call
            Logger.info("\(self.logTag) called \(#function)")
            self.call!.leaveCall()
        }
        
    }
    
    @IBAction func didDoubleTapMainPeerView(_ sender: UITapGestureRecognizer) {
        switch sender.state {
        case .possible:
            do { /* Do nothin' */ }
        case .began:
            do { /* Do nothin' */ }
        case .changed:
            do { /* Do nothin' */ }
        case .ended:
            do { /* Do things here */ }
        case .cancelled:
            do { /* Do nothin' */ }
        case .failed:
            do { /* Do nothin' */ }
        }
    }
    
    @IBAction func didLongPressMainPeerView(_ sender: UILongPressGestureRecognizer) {
        switch sender.state {
            
        case .possible:
            do { /* Do nothin' */ }
        case .began:
            do { /* Do things here */ }
        case .changed:
            do { /* Do nothin' */ }
        case .ended:
            do { /* Do nothin' */ }
        case .cancelled:
            do { /* Do nothin' */ }
        case .failed:
            do { /* Do nothin' */ }
        }
    }
    
    /*
     // MARK: - Navigation
     
     // In a storyboard-based application, you will often want to do a little preparation before navigation
     override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
     // Get the new view controller using [segue destinationViewController].
     // Pass the selected object to the new view controller.
     }
     */
    
    // MARK: - Call Service Delegate methods
    func createdConferenceCall(call: ConferenceCall) {
        // TODO: implement
    }
    
    // MARK: - ConferenceCall delegate methods
    func audioSourceDidChange(call: ConferenceCall, audioSource: AudioSource?) {
        // TODO: update UI as appropriate
    }
    
    func peerConnectionStateDidChange(pcc: PeerConnectionClient, oldState: PeerConnectionClientState, newState: PeerConnectionClientState) {
        
        guard pcc.callId == self.call?.callId else {
            Logger.debug("\(self.logTag): Dropping peer connect state change for obsolete call.")
            return
        }
        guard oldState != newState else {
            Logger.debug("*** GEP WTF? ***\(self.logTag): Received peer connection state (\(oldState)) update that didn't change.")
            return
        }
        
        // Check for a SUCCESSFUL new peer and build the pieces-parts for it
        if oldState == .undefined && !newState.isTerminal {
            if call?.peerConnectionClients[pcc.peerId] != nil {
                // Check to see if we already have a view collection for this peer
                if self.peerUIElements[pcc.peerId] == nil {
                    // We don't have this one, build it
                    self.addSecondaryPeerId(pcc.peerId)
                }
            }
        }
        self.updatePeerUIElement(pcc.peerId, animated: true)
        
        // Clean up the video track if its going away
        if newState.isTerminal {
                self.removePeerFromView(pcc.peerId)
        }
        
        // Check to see if this is the last peer
        if self.call != nil {
            var allAlone = true
            for peer in self.call!.peerConnectionClients.values {
                if !peer.state.isTerminal {
                    allAlone = false
                    break
                }
            }
            if allAlone {
                // tear down the call
                self.call!.leaveCall()
            }
        }
    }
    
    func stateDidChange(call: ConferenceCall, oldState: ConferenceCallState, newState: ConferenceCallState) {
        
        guard self.call?.callId == call.callId else {
            Logger.debug("\(self.logTag) dropping call state change mismatched callId.")
            return
        }
        
        guard oldState != newState else {
            return
        }
        
        switch newState {
        case .undefined:
            do { /* TODO */ }
        case .ringing:
            do { /* TODO */ }
        case .vibrating:
            do { /* TODO */ }
        case .rejected:
            do { /* TODO */ }
        case .joined:
            do {
                self.updateUIForCallPolicy()
            }
        case .leaving:
            do { /* TODO */ }
        case .left:
            do {
                self.call = nil
                self.dismissIfPossible(shouldDelay: true)
            }
        }
    }
    
    func peerConnectiongDidUpdateRemoteVideoTrack(peerId: String) {
        guard let peerConnection = self.call?.peerConnectionClients[peerId] else {
            Logger.debug("\(self.logTag): received video track update for unknown peerId: \(peerId)")
            return
        }
        if let avView = self.peerUIElements[peerId]?.avView {
            peerConnection.remoteVideoTrack?.add(avView)
            (avView as UIView).isHidden = false
        }
    }
    
    func didUpdateLocalVideoTrack(captureSession: AVCaptureSession?) {
        if captureSession != nil {
            self.localAVView.captureSession = captureSession
            self.localAVView.isHidden = false
        } else {
            self.localAVView.isHidden = true
        }
    }
}

// MARK: - UICollectionViewDelegate & UICollectionViewDataSource methods

extension ConferenceCallViewController : UICollectionViewDelegate, UICollectionViewDataSource, PeerViewsLayoutDelegate
{
    
    func numberOfSections(in collectionView: UICollectionView) -> Int {
        // #warning Incomplete implementation, return the number of sections
        return 1
    }
    
    
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        // #warning Incomplete implementation, return the number of items
        return self.secondaryPeerIds.count
    }
    
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell: PeerViewCell = collectionView.dequeueReusableCell(withReuseIdentifier: reuseIdentifier, for: indexPath) as! PeerViewCell
        
        
        let peerId = self.secondaryPeerIds[indexPath.item]
        
        if let peer = self.call?.peerConnectionClients[peerId] {
            if let avatarImage = FLContactsManager.shared.avatarImageRecipientId(peer.userId) {
                cell.avatarImageView.image = avatarImage
            } else {
                cell.avatarImageView.image = UIImage(named: "actionsheet_contact")
            }
            
            if self.call?.peerConnectionClients[peerId]?.remoteVideoTrack != nil {
                self.call?.peerConnectionClients[peerId]?.remoteVideoTrack?.add(cell.avView)
            }
            cell.avView.isHidden = (peer.state == .connected ? false : true)
            
            
            // TODO: put a fine line border
            cell.layer.borderWidth = 0.25
            cell.layer.borderColor = UIColor.gray.cgColor
            
            cell.statusIndicatorView.layer.cornerRadius = cell.statusIndicatorView.frame.size.width/2
            
            let peerUI = PeerUIElements()
            peerUI.avView = cell.avView
            peerUI.avatarView = cell.avatarImageView
            peerUI.statusIndicator = cell.statusIndicatorView
            peerUI.statusView = cell.statusIndicatorView
            
            self.peerUIElements[peerId] = peerUI
        }
        
        return cell
    }
    
    
    /*
     func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
     let cell = collectionView.cellForItem(at: indexPath) as! PeerViewCell
     cell.avView.isHidden = false
     }
     */
    
    /*
     // Uncomment this method to specify if the specified item should be highlighted during tracking
     override func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
     return true
     }
     */
    
    /*
     // Uncomment this method to specify if the specified item should be selected
     override func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
     return true
     }
     */
    
    /*
     // Uncomment these methods to specify if an action menu should be displayed for the specified item, and react to actions performed on the item
     override func collectionView(_ collectionView: UICollectionView, shouldShowMenuForItemAt indexPath: IndexPath) -> Bool {
     return false
     }
     
     override func collectionView(_ collectionView: UICollectionView, canPerformAction action: Selector, forItemAt indexPath: IndexPath, withSender sender: Any?) -> Bool {
     return false
     }
     
     override func collectionView(_ collectionView: UICollectionView, performAction action: Selector, forItemAt indexPath: IndexPath, withSender sender: Any?) {
     
     }
     */
    
    // MARK: Layout delegate method(s)
    func peerViewDiameter() -> CGFloat {
        return 100
    }
}


class PeerUIElements {
    var avView: RemoteVideoView?
    var avatarView: UIImageView?
    var statusIndicator: UIView?
    var statusView: UIView?
    var statusLabel: UILabel?
}
