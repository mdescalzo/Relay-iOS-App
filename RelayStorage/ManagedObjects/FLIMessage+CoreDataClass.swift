//
//  FLIMessage+CoreDataClass.swift
//  
//
//  Created by Mark Descalzo on 4/18/19.
//
//

import Foundation
import CoreData

@objc(FLIMessage)
public class FLIMessage: BaseChatObject {
  
    enum FLIMessageType : String {
        case FLIMessageTypeContent = "content"
        case FLIMessageTypePoll = "poll"
        case FLIMessageTypePollResponse = "pollResponse"
        case FLIMessageTypeControl = "control"
        case FLIMessageTypeReceipt = "receipt"
    }

    @objc func isRead() -> Bool {
        // TODO: Add logic here
        return false
    }

}
