//
//  File.swift
//  RelayMessaging
//
//  Created by Mark Descalzo on 4/29/19.
//  Copyright © 2019 Forsta Labs, Inc. All rights reserved.
//

import Foundation
import RelayStorage
import CoreData

@objc class UserViewModel: NSObject {
    @objc let userId: String
    @objc let fullName: String
    @objc var avatar: UIImage? = nil

    @objc init?(user: FLIUser) {
        
        userId = user.uuid!
        fullName = user.fullName()
        if let data = user.avatar as Data? {
        avatar = UIImage(data:data)
        }
        
        super .init()
    }
}
