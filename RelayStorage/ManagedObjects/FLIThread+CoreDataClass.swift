//
//  FLIThread+CoreDataClass.swift
//  
//
//  Created by Mark Descalzo on 4/18/19.
//
//

import Foundation
import CoreData


@objc(FLIThread)
public class FLIThread: BaseChatObject {
    
    public enum FLIThreadType : String {
        case FLIThreadTypeAnnouncement = "announcement"
        case FLIThreadTypeConversation = "conversation"
    }
    
    @objc public func displayName() -> String {
        var returnString: String
        
        if title?.count ?? 0 > 0 {
            returnString = title!
        } else if currentParticipants?.count == 1 && (currentParticipants?.anyObject() as? FLIUser)!.uuid == BigDummy.localuuid {
            returnString = NSLocalizedString("ME_STRING", comment: "")
        } else if let user = otherParticipant() {
            returnString = user.fullName()
        } else if pretty?.count ?? 0 > 0 {
            returnString = pretty!
        } else {
            returnString = NSLocalizedString("NEW_THREAD", comment: "")
        }
        return returnString.trimmingCharacters(in: CharacterSet.whitespaces)
    }
    
    @objc public func isOneOnOne() -> Bool {
        guard let participants = currentParticipants as? Set<FLIUser> else {
            return false
        }
        if participants.count == 2 && participants.contains(where: { (user:FLIUser) -> Bool in user.uuid == BigDummy.localuuid}) {
            return true
        } else {
            return false
        }
    }
    
    @objc public func otherParticipant() -> FLIUser? {
        guard let participants = currentParticipants as? Set<FLIUser> else {
            return nil
        }

        if isOneOnOne() {
            for user in participants {
                if !(user.uuid == BigDummy.localuuid) {
                    return user
                }
            }
        }
        return nil
    }

    @objc public func lastMessage() -> FLIMessage? {
        guard messages?.count ?? 0 > 0 else {
            return nil
        }
        
        let sorter = NSSortDescriptor(key: "sentDate", ascending: true)
        if let sortedMessages = messages!.sortedArray(using: [sorter]) as? [FLIMessage] {
            return sortedMessages.last
        }
        return nil
    }
    
    @objc public func unreadMessageCount() -> UInt {
        //  FIXME: Build fetch request of count return type and predicate that filters on unread.
        //  TODO: Build into threadManager a FetchResultsController which tracks unread values for us. 
        
        return 42
    }
}
