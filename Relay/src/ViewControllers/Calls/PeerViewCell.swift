//
//  PeerViewCell.swift
//  CallUITestBed
//
//  Created by Mark Descalzo on 2/4/19.
//  Copyright © 2019 Ringneck Software, LLC. All rights reserved.
//

import UIKit

class PeerViewCell: UICollectionViewCell {
    @IBOutlet weak var avView: RemoteVideoView!
    @IBOutlet weak var avatarImageView: UIImageView!
    @IBOutlet weak var statusIndicatorView: UIView!
    @IBOutlet weak var silenceIndicator: UIImageView!
    @IBOutlet weak var videoIndicator: UIImageView!
    
    weak var rtcVideoTrack: RTCVideoTrack?
    
    override func prepareForReuse() {
        rtcVideoTrack?.remove(avView)
        avView.isHidden = true
        statusIndicatorView.isHidden = true
        avatarImageView.image = nil
        
        super.prepareForReuse()
    }
}
