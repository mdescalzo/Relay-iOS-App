//
//  ConferenceCallCollectionViewController.swift
//  CallUITestBed
//
//  Created by Mark Descalzo on 1/31/19.
//  Copyright © 2019 Ringneck Software, LLC. All rights reserved.
//

import UIKit

private let reuseIdentifier = "peerCell"

class ConferenceCallViewController: UIViewController, ConferenceCallServiceDelegate , ConferenceCallDelegate {
    
    var mainPeerId: String?
    
    var secondaryPeerIds = [String]()
    
    var peerUIElements = [ String : PeerUI ]()
    var hasDismissed = false
    
    lazy var callKitService = {
        return CallUIService.shared
    }()
    
    @IBOutlet var stackContainerView: UIStackView!
    
    @IBOutlet weak var mainPeerAVView: RemoteVideoView!
    @IBOutlet weak var mainPeerAvatarView: UIImageView!
    @IBOutlet weak var localAVView: RTCCameraPreviewView!
    var hasLocalVideo = true
    
    @IBOutlet weak var infoContainerView: UIView!
    @IBOutlet weak var infoLabel: UILabel!
    @IBOutlet weak var collectionView: UICollectionView!
    @IBOutlet weak var collectionViewHeightConstraint: NSLayoutConstraint!
    @IBOutlet weak var controlsContainerView: UIView!
    @IBOutlet weak var muteButton: UIButton!
    @IBOutlet weak var videoToggleButton: UIButton!
    @IBOutlet weak var audioOutButton: UIButton!
    @IBOutlet weak var leaveCallButton: UIButton!
    
    var call: ConferenceCall?
    
    func configure(call: ConferenceCall) {
        self.call = call
        self.call?.addDelegate(delegate: self)
        
        for peer in (self.call?.peerConnectionClients.values)! {
            if peer.userId == self.call?.originatorId {
                self.setPeerIdAsMain(peerId: peer.peerId)
            } else {
                self.addSecondaryPeerId(peerId: peer.peerId)
            }
        }
    }
    
    override func loadView() {
        super.loadView()
        
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Uncomment the following line to preserve selection between presentations
        // self.clearsSelectionOnViewWillAppear = false
        
        // Register cell classes - only use if not using Storyboard
        //        self.collectionView!.register(PeerViewCell.self, forCellWithReuseIdentifier: reuseIdentifier)
        
        // Do any additional setup after loading the view.
        
        // Build collection of references to the AV views
        guard self.call != nil else {
            owsFailDebug("\(self.logTag): CallViewController loaded with nil object!")
            self.dismissImmediately(completion: nil)
            return
        }
        
        // Setup main peer views
        if self.mainPeerId != nil {
            // Setup the avatar view
            if let mainPeer = self.call?.peerConnectionClients[self.mainPeerId!] {
                if let avatarImage = FLContactsManager.shared.avatarImageRecipientId(mainPeer.userId) {
                    self.mainPeerAvatarView.image = avatarImage
                } else {
                    self.mainPeerAvatarView.image = UIImage(named: "actionsheet_contact")
                }
            }
            // Setup the video view
            if let client = self.call?.peerConnectionClients[mainPeerId!] {
                client.remoteVideoTrack?.add(self.mainPeerAVView)
                self.mainPeerAVView.isHidden = false
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
        
        // Handle any peers added before the UI was built
        for peerId in self.secondaryPeerIds {
            self.addSecondaryPeerId(peerId: peerId)
        }
    }
    
    // MARK: - Helpers
    private func setPeerIdAsMain(peerId: String) {
        self.mainPeerId = peerId
        let mainPeerUI = PeerUI()
        mainPeerUI.avatarView = self.mainPeerAvatarView
        mainPeerUI.avView = self.mainPeerAVView
        self.peerUIElements[self.mainPeerId!] = mainPeerUI
    }
    
    private func addSecondaryPeerId(peerId: String) {
        guard self.collectionView != nil else {
            self.secondaryPeerIds.append(peerId)
            return
        }
        
        self.collectionView.performBatchUpdates({
            let index = self.secondaryPeerIds.count
            self.secondaryPeerIds.insert(peerId, at: index)
            self.collectionView.insertItems(at: [IndexPath(item: index, section: 0)])
        }, completion: nil)
    }
    
    private func removeSecondaryPeerId(peerId: String) {
        guard self.collectionView != nil else {
            if let index = self.secondaryPeerIds.firstIndex(of: peerId) {
                self.secondaryPeerIds.remove(at: index)
            }
            return
        }
        
        self.collectionView.performBatchUpdates({
            if let index = self.secondaryPeerIds.firstIndex(of: peerId) {
                self.secondaryPeerIds.remove(at: index)
                self.collectionView.deleteItems(at: [IndexPath(item: index, section: 0)])
            }
        }, completion: nil)
    }
    
    private func updateStatusIndicator(peerId: String, color: UIColor, hide: Bool) {
        if let peerElements = self.peerUIElements[peerId] {
            let duration = 0.25
            UIView.animate(withDuration: duration, animations: {
                peerElements.avView?.isHidden = false
                peerElements.statusIndicatorView?.backgroundColor = UIColor.green
            }) { (complete) in
                if color == UIColor.clear || hide {
                    UIView.animate(withDuration: duration, animations: {
                        peerElements.statusIndicatorView?.isHidden = true
                    })
                }
            }
        }
    }
    
    private func updatePeerViewHeight() {
        let oldValue = self.collectionViewHeightConstraint.constant
        
        var newValue: CGFloat
        
        if self.secondaryPeerIds.count > 0 {
            newValue = UIScreen.main.bounds.width/4 - 8
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
    @objc func didDoubleTapCollectionView(gesture: UITapGestureRecognizer) {
        let pointInCollectionView = gesture.location(in: self.collectionView)
        if let selectedIndexPath = self.collectionView.indexPathForItem(at: pointInCollectionView) {
            let selectedCell = self.collectionView.cellForItem(at: selectedIndexPath) as! PeerViewCell
            selectedCell.avView.isHidden = true
        }
    }
    
    @objc func didLongPressCollectionView(gesture: UITapGestureRecognizer) {
        let pointInCollectionView = gesture.location(in: self.collectionView)
        if let selectedIndexPath = self.collectionView.indexPathForItem(at: pointInCollectionView) {
            let selectedCell = self.collectionView.cellForItem(at: selectedIndexPath) as! PeerViewCell
            selectedCell.avView.isHidden = true
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
    
    @IBAction func didTapAudioOutputButton(_ sender: Any) {
        Logger.info("\(self.logTag) called \(#function)")
    }
    
    @IBAction func didTapEndCallButton(_ sender: Any) {
        Logger.info("\(self.logTag) called \(#function)")
        if self.call != nil {
            self.callKitService.localHangupCall(call!)
            self.call = nil
        }
        self.dismissIfPossible(shouldDelay: false, completion: nil)
    }
    
    @IBAction func didDoubleTapLocalUserView(_ sender: UITapGestureRecognizer) {
        switch sender.state {
        case .possible:
            do { /* Do nothin' */ }
        case .began:
            do { /* Do nothin' */ }
        case .changed:
            do { /* Do nothin' */ }
        case .ended:
            do {
                self.localAVView.isHidden = !self.localAVView.isHidden
            }
        case .cancelled:
            do { /* Do nothin' */ }
        case .failed:
            do { /* Do nothin' */ }
        }
    }
    
    @IBAction func didLongPressLocalUserView(_ sender: UILongPressGestureRecognizer) {
        switch sender.state {
            
        case .possible:
            do { /* Do nothin' */ }
        case .began:
            do {
                self.localAVView.isHidden = !self.localAVView.isHidden
            }
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
    
    @IBAction func didDoubleTapMainPeerView(_ sender: UITapGestureRecognizer) {
        switch sender.state {
        case .possible:
            do { /* Do nothin' */ }
        case .began:
            do { /* Do nothin' */ }
        case .changed:
            do { /* Do nothin' */ }
        case .ended:
            do {
                self.mainPeerAVView.isHidden = !self.mainPeerAVView.isHidden
            }
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
            do {
                self.mainPeerAVView.isHidden = !self.mainPeerAVView.isHidden
            }
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
        // a stub
    }
    
    // MARK: - Call delegate methods
    func peerConnectionStateDidChange(callId: String, peerId: String, oldState: PeerConnectionClientState, newState: PeerConnectionClientState) {
        
        guard callId == self.call?.callId else {
            Logger.debug("\(self.logTag): Dropping peer connect state change for obsolete call.")
            return
        }
        
        guard oldState != newState else {
            Logger.debug("\(self.logTag): Received peer connection state (\(oldState)) update that didn't change.")
            return
        }
        
        // Check for a new peer and build the pieces-parts for it
        if oldState == .undefined {
            if let peer = call?.peerConnectionClients[peerId] {
                if call?.direction == .incoming {
                    if peer.userId == self.call?.originatorId {
                        self.setPeerIdAsMain(peerId: peerId)
                    } else {
                        self.addSecondaryPeerId(peerId: peerId)
                    }
                } else {
                    if self.mainPeerId == nil {
                        self.mainPeerId = peerId
                    } else {
                        self.addSecondaryPeerId(peerId: peerId)
                    }
                }
            }
        }
        
        if let peerElements = self.peerUIElements[peerId] {
            switch newState {
            case .undefined:
                do {
                    peerElements.avView?.isHidden = true
                    self.updateStatusIndicator(peerId: peerId, color: UIColor.clear, hide: true)
                }
            case .connected:
                do {
                    peerElements.avView?.isHidden = false
                    self.updateStatusIndicator(peerId: peerId, color: UIColor.green, hide: true)
                }
            case .peerLeft:
                do {
                    peerElements.avView?.isHidden = true
                    self.updateStatusIndicator(peerId: peerId, color: UIColor.gray, hide: false)
                }
            case .leftPeer:
                do {
                    peerElements.avView?.isHidden = true
                    self.updateStatusIndicator(peerId: peerId, color: UIColor.gray, hide: false)
                }
            case .discarded:
                do {
                    peerElements.avView?.isHidden = true
                    self.updateStatusIndicator(peerId: peerId, color: UIColor.black, hide: true)
                    // TODO:  nuke the UI for this peer
                }
            case .failed:
                do {
                    peerElements.avView?.isHidden = true
                    self.updateStatusIndicator(peerId: peerId, color: UIColor.red, hide: false)
                }
            case .sendingAcceptOffer:
                do {
                    peerElements.avView?.isHidden = true
                    self.updateStatusIndicator(peerId: peerId, color: UIColor.yellow, hide: false)
                }
            case .sentAcceptOffer:
                do {
                    peerElements.avView?.isHidden = true
                    self.updateStatusIndicator(peerId: peerId, color: UIColor.yellow, hide: false)
                }
            case .sendingOffer:
                do {
                    peerElements.avView?.isHidden = true
                    self.updateStatusIndicator(peerId: peerId, color: UIColor.yellow, hide: false)
                }
            case .readyToReceiveAcceptOffer:
                do {
                    peerElements.avView?.isHidden = true
                    self.updateStatusIndicator(peerId: peerId, color: UIColor.yellow, hide: false)
                }
            case .receivedAcceptOffer:
                do {
                    peerElements.avView?.isHidden = true
                    self.updateStatusIndicator(peerId: peerId, color: UIColor.yellow, hide: false)
                }
            }
        }
    }
    
    func stateDidChange(call: ConferenceCall, oldState: ConferenceCallState, newState: ConferenceCallState) {
        // ConferenceCallViewController don't care (yet)
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
        
        let peer = self.call?.peerConnectionClients[peerId]
        if let avatarImage = FLContactsManager.shared.avatarImageRecipientId((peer?.userId)!) {
            cell.avatarImageView.image = avatarImage
        } else {
            cell.avatarImageView.image = UIImage(named: "actionsheet_contact")
        }
        
        if self.call?.peerConnectionClients[peerId]?.remoteVideoTrack != nil {
            self.call?.peerConnectionClients[peerId]?.remoteVideoTrack?.add(cell.avView)
            cell.avView.isHidden = false
        }
        
        // TODO: put a fine black line border
        cell.layer.borderWidth = 0.25
        cell.layer.borderColor = UIColor.black.cgColor
        
        cell.statusIndicatorView.layer.cornerRadius = cell.statusIndicatorView.frame.size.width/2
        
        let peerUI = PeerUI()
        peerUI.avView = cell.avView
        peerUI.avatarView = cell.avatarImageView
        peerUI.statusIndicatorView = cell.statusIndicatorView
        
        self.peerUIElements[peerId] = peerUI
        
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


class PeerUI {
    var avView: RemoteVideoView?
    var avatarView: UIImageView?
    var statusIndicatorView: UIView?
}