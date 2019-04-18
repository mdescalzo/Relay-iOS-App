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
    @objc let lastMessageDate: Date
    @objc let unreadCount: UInt
    @objc let title: String
    @objc let isMuted: Bool


    @objc let lastMessageText: String?
    @objc let lastMessageForInbox: FLIMessage?

    @objc
    init(thread: FLIThread) {
        self.threadId = thread.uuid
        self.lastMessageDate = thread.lastMessage().sentDate
        self.title = thread.displayName()
        self.isMuted = thread.isMuted
        self.lastMessageText = thread.lastMessage().plainText
        self.lastMessageForInbox = thread.lastMessage()
        self.unreadCount = thread.unreadMessageCount(transaction: transaction)
        self.hasUnreadMessages = unreadCount > 0
    }

    @objc
    override func isEqual(_ object: Any?) -> Bool {
        guard let otherThread = object as? ThreadViewModel else {
            return super.isEqual(object)
        }
        return threadId == otherThread.threadId
    }
}
