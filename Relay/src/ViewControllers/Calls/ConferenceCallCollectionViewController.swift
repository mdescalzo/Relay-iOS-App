//
//  ConferenceCallCollectionViewController.swift
//  CallUITestBed
//
//  Created by Mark Descalzo on 1/31/19.
//  Copyright © 2019 Ringneck Software, LLC. All rights reserved.
//

import UIKit

private let reuseIdentifier = "peerCell"

class ConferenceCallCollectionViewController: UIViewController {
    
    // Test UI begin
    @IBAction func addPeerTap(_ sender: Any) {
        let totalItems = self.collectionView.numberOfItems(inSection: 0)

        if totalItems < 20 {
            self.peers.append(PeerPlaceholder())
            self.updatePeerViewHeight()
            self.collectionView.performBatchUpdates({
                self.collectionView.insertItems(at: [IndexPath(item: totalItems, section: 0)])
            }, completion: nil)
        }
    }
    @IBAction func removePeerTap(_ sender: Any) {
        let totalItems = self.collectionView.numberOfItems(inSection: 0)

        if totalItems > 0 {
            self.peers.remove(at: totalItems - 1)
            self.updatePeerViewHeight()
            self.collectionView.performBatchUpdates({
                self.collectionView.deleteItems(at: [IndexPath(item: totalItems-1, section: 0)])
            }, completion: nil)
        }
    }
    
    private func buildPeerCollection(count: Int) {
        self.peers.removeAll()
        // populate dummy content
        for _ in 0..<count { peers.append(PeerPlaceholder()) }
    }
    // Test UI end
    
    var peers = [PeerPlaceholder]()

    @IBOutlet var stackContainerView: UIStackView!

    @IBOutlet weak var mainPeerAVView: UIView!
    @IBOutlet weak var localAVView: UIView!
    @IBOutlet weak var localAvatarImageView: UIImageView!
    @IBOutlet weak var infoContainerView: UIView!
    @IBOutlet weak var collectionView: UICollectionView!
    @IBOutlet weak var collectionViewHeightConstraint: NSLayoutConstraint!
    @IBOutlet weak var controlsContainerView: UIView!
    @IBOutlet weak var muteButton: UIButton!
    @IBOutlet weak var videoToggleButton: UIButton!
    @IBOutlet weak var audioOutButton: UIButton!
    
    override func loadView() {
        super.loadView()
        
        self.buildPeerCollection(count: 6)
        
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
        self.updatePeerViewHeight()
        
        // Peer view setup
        if let layout = self.collectionView?.collectionViewLayout as? PeerViewsLayout {
            layout.delegate = self
        }
        
        // Gesture handlers
        let doubleTapGestureRecognizer = UITapGestureRecognizer(target: self,
                                                                action: #selector(ConferenceCallCollectionViewController.didDoubleTapCollectionView(gesture:)))
        doubleTapGestureRecognizer.numberOfTapsRequired = 2
        self.collectionView.addGestureRecognizer(doubleTapGestureRecognizer)

        let longPressGestureRecognizer = UILongPressGestureRecognizer(target: self,
                                                                action: #selector(ConferenceCallCollectionViewController.didLongPressCollectionView(gesture:)))
        self.collectionView.addGestureRecognizer(longPressGestureRecognizer)

        
    }
    
    // MARK: - Helpers
    private func updatePeerViewHeight() {
        let oldValue = self.collectionViewHeightConstraint.constant
        
        var newValue: CGFloat
        
        if self.peers.count > 0 {
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




}

extension ConferenceCallCollectionViewController : UICollectionViewDelegate, UICollectionViewDataSource, PeerViewsLayoutDelegate
{
    
    // MARK: UICollectionViewDataSource
    
    func numberOfSections(in collectionView: UICollectionView) -> Int {
        // #warning Incomplete implementation, return the number of sections
        return 1
    }
    
    
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        // #warning Incomplete implementation, return the number of items
        return self.peers.count
    }
    
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell: PeerViewCell = collectionView.dequeueReusableCell(withReuseIdentifier: reuseIdentifier, for: indexPath) as! PeerViewCell

        cell.avatarImageView.image = UIImage(named: "avatar")

        cell.avView.backgroundColor = UIColor.green
        
        cell.layer.cornerRadius = self.peerViewDiameter()/8

        return cell
    }
    

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
//        let index = indexPath.row
        
        let cell = collectionView.cellForItem(at: indexPath) as! PeerViewCell
        cell.avView.isHidden = false
    }
    
    // MARK: UICollectionViewDelegate

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

class PeerPlaceholder: UIImage
{
    let avatar = UIImage(named: "avatar")
}
