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
}
