//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

import Foundation
import RelayStorage
import CoreData

@objc
class ThreadViewModel: NSObject {
    @objc let threadId: String
    @objc let hasUnreadMessages: Bool
    @objc let lastMessageDate: Date?
    @objc let unreadCount: UInt
    @objc let title: String
    @objc let isMuted: Bool


    @objc let lastMessageText: String?
    @objc let lastMessageForInbox: FLIMessage?

    @objc
    init(thread: FLIThread) {
        threadId = thread.uuid!
        lastMessageDate = thread.lastMessage()?.sentDate as Date?
        title = thread.displayName()
        isMuted = (thread.mutedUntilDate != nil)
        lastMessageText = thread.lastMessage()?.plainText
        lastMessageForInbox = thread.lastMessage()
        unreadCount = thread.unreadMessageCount()
        hasUnreadMessages = unreadCount > 0
        
        super.init()
    }

    @objc
    override func isEqual(_ object: Any?) -> Bool {
        guard let otherThread = object as? ThreadViewModel else {
            return super.isEqual(object)
        }
        return threadId == otherThread.threadId
    }
}
