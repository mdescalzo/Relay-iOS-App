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
    
    var peerAVViews = [String : RTCVideoRenderer]()
    var hasDismissed = false

    @IBOutlet var stackContainerView: UIStackView!

    @IBOutlet weak var mainPeerAVView: RemoteVideoView!
    @IBOutlet weak var localAVView: RTCCameraPreviewView!
    @IBOutlet weak var localAvatarImageView: UIImageView!
    @IBOutlet weak var infoContainerView: UIView!
    @IBOutlet weak var collectionView: UICollectionView!
    @IBOutlet weak var collectionViewHeightConstraint: NSLayoutConstraint!
    @IBOutlet weak var controlsContainerView: UIView!
    @IBOutlet weak var muteButton: UIButton!
    @IBOutlet weak var videoToggleButton: UIButton!
    @IBOutlet weak var audioOutButton: UIButton!
    
    var call: ConferenceCall?
    lazy var callUIAdapter:CallUIAdapter? = { return ConferenceCallService.shared.callUIAdapter }()

    func configure(call: ConferenceCall) {
        self.call = call
        self.call?.addDelegate(delegate: self)
        self.mainPeerId = self.call?.peerConnectionClients.keys.first
        self.secondaryPeerIds = (self.call?.peerConnectionClients.keys.filter({ (peer) -> Bool in
            peer != mainPeerId
        }))!
    }
    
    override func loadView() {
        super.loadView()
        
        // Main Container View setup
        
        // Infomation container view setup

        // Collection view setup
        
        // Controls container view setup
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
        
        if self.mainPeerId != nil {
            self.peerAVViews[mainPeerId!] = self.mainPeerAVView
            if let client = self.call?.peerConnectionClients[mainPeerId!] {
                client.remoteVideoTrack?.add(self.mainPeerAVView)
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

        
    }
    
    // MARK: - Helpers
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
        callUIAdapter!.audioService.delegate = nil
        
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

    @IBAction func didTapMuteButton(_ sender: Any) {
        self.muteButton.isSelected = !self.muteButton.isSelected
    }
    
    @IBAction func didTapVideoToggleButton(_ sender: Any) {
        self.videoToggleButton.isSelected = !self.videoToggleButton.isSelected
    }
    
    @IBAction func didTapAudioOutputButton(_ sender: Any) {
    }
    
    @IBAction func didTapEndCallButton(_ sender: Any) {
        if self.call != nil,
            self.callUIAdapter != nil {
            self.callUIAdapter!.localHangupCall(self.call!)
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
    func stateDidChange(call: ConferenceCall, state: ConferenceCallState) {
        // a stub
    }
    
    func peerConnectionDidConnect(peerId: String) {
        // a stub
    }
    
    func peerConnectiongDidUpdateRemoteVideoTrack(peerId: String) {
        guard let peerConnection = self.call?.peerConnectionClients[peerId] else {
            Logger.debug("\(self.logTag): received video track update for unknown peerId: \(peerId)")
            return
        }
        if self.peerAVViews[peerId] != nil {
            peerConnection.remoteVideoTrack?.add(self.peerAVViews[peerId]!)
            (self.peerAVViews[peerId]! as! UIView).isHidden = false
        }
    }

//    func rendererViewFor(peerId: String) -> RTCVideoRenderer? {
//        if let peerView = self.peerAVViews[peerId] {
//            return peerView
//        } else {
//            Logger.info("Received video track update for unknown peer: \(peerId)")
//            return nil
//        }
//    }
//
//    func videoTrackDidUpdateFor(peerId: String) {
//        // a stub
//    }
//
//    func updateCall(call: ConferenceCall) {
//        // a stub
//    }
//
//    func stateDidChange(call: ConferenceCall, state: ConferenceCallState) {
//        // a stub
//    }
//
//    func peerConnectionDidConnect(peerId: String) {
//        // a stub
//    }

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
        
        cell.avatarImageView.image = UIImage(named: "avatar")
        cell.avView.backgroundColor = UIColor.green

        let peerId = self.secondaryPeerIds[indexPath.item]
        self.peerAVViews[peerId] = cell.avView
        
        self.call?.peerConnectionClients[peerId]?.remoteVideoTrack?.add(cell.avView)
        
        // TODO: put a fine black line border
//        cell.layer.cornerRadius = self.peerViewDiameter()/8

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
