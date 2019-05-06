//  Created by Michael Kirk on 12/18/16.
//  Copyright © 2016 Open Whisper Systems. All rights reserved.

import Foundation

struct TurnServerInfo {

    let TAG = "[TurnServerInfo]"
    let password: String
    let username: String
    let urls: [String]

    init?(attributes: [String: AnyObject]) {
        username = (attributes["username"] as? String) ?? ""
        password = (attributes["credential"] as? String) ?? ""
        
        if let singular = attributes["urls"] as? String {
            urls = [singular]
        } else if let plural = attributes["urls"] as? [String] {
            urls = plural
        } else {
            return nil
        }
    }
}
