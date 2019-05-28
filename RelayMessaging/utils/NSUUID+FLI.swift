//
//  NSUUID+FLI.swift
//  RelayMessaging
//
//  Created by Mark on 5/28/19.
//  Copyright © 2019 Forsta Labs, Inc. All rights reserved.
//

import Foundation

@objc
extension NSUUID {
    public func normalizedUUIDString(from string: String) -> String? {
        return NSUUID(uuidString: string)?.uuidString
    }
}
