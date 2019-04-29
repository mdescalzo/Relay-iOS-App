//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

import UIKit

@objc
public class AvatarImageView: UIImageView {

    public init() {
        super.init(frame: .zero)
        self.configureView()
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.configureView()
    }

    required public init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        self.configureView()
    }

    override init(image: UIImage?) {
        super.init(image: image)
        self.configureView()
    }

    func configureView() {
        self.autoPinToSquareAspectRatio()

        self.layer.minificationFilter = kCAFilterTrilinear
        self.layer.magnificationFilter = kCAFilterTrilinear
        self.layer.borderWidth = 0.5
        self.layer.masksToBounds = true
        self.contentMode = .scaleToFill
    }

    override public func layoutSubviews() {
        self.layer.borderColor = UIColor.black.cgColor.copy(alpha: 0.15)
        self.layer.cornerRadius = self.frame.size.width / 2
    }
}

/// Avatar View which updates itself as necessary when the profile, contact, or group picture changes.
@objc
public class ConversationAvatarImageView: AvatarImageView {

    let thread: TSThread
    let diameter: UInt
    let contactsManager: FLIUserManager

//    // nil if group avatar
//    let recipientId: String?

    // nil if contact avatar
    let groupThreadId: String?

    required public init(thread: TSThread, diameter: UInt, contactsManager: FLIUserManager) {
        self.thread = thread
        self.diameter = diameter
        self.contactsManager = contactsManager

        self.groupThreadId = thread.uniqueId

        super.init(frame: .zero)

//        if recipientId != nil {
//            NotificationCenter.default.addObserver(self, selector: #selector(handleOtherUsersProfileChanged(notification:)), name: NSNotification.Name(rawValue: kNSNotificationName_OtherUsersProfileDidChange), object: nil)
//
//            NotificationCenter.default.addObserver(self, selector: #selector(handleSignalAccountsChanged(notification:)), name: NSNotification.Name.OWSContactsManagerSignalAccountsDidChange, object: nil)
//        }

        if groupThreadId != nil {
            NotificationCenter.default.addObserver(self, selector: #selector(handleGroupAvatarChanged(notification:)), name: .TSThreadAvatarChanged, object: nil)
        }

        // TODO group avatar changed
        self.updateImage()
    }

    required public init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc func handleSignalAccountsChanged(notification: Notification) {
        Logger.debug("\(self.logTag) in \(#function)")

        // PERF: It would be nice if we could do this only if *this* user's SignalAccount changed,
        // but currently this is only a course grained notification.

        self.updateImage()
    }

    @objc func handleOtherUsersProfileChanged(notification: Notification) {
        Logger.debug("\(self.logTag) in \(#function)")

        guard let changedRecipientId = notification.userInfo?[kNSNotificationKey_ProfileRecipientId] as? String else {
            owsFailDebug("\(logTag) in \(#function) recipientId was unexpectedly nil")
            return
        }

//        guard let recipientId = self.recipientId else {
//            // shouldn't call this for group threads
//            owsFailDebug("\(logTag) in \(#function) contactId was unexpectedly nil")
//            return
//        }

//        guard recipientId == changedRecipientId else {
//            // not this avatar
//            return
//        }

        self.updateImage()
    }

    @objc func handleGroupAvatarChanged(notification: Notification) {
        Logger.debug("\(self.logTag) in \(#function)")

        guard let changedGroupThreadId = notification.userInfo?[TSThread_NotificationKey_UniqueId] as? String else {
            owsFailDebug("\(logTag) in \(#function) groupThreadId was unexpectedly nil")
            return
        }

        guard let groupThreadId = self.groupThreadId else {
            // shouldn't call this for contact threads
            owsFailDebug("\(logTag) in \(#function) groupThreadId was unexpectedly nil")
            return
        }

        guard groupThreadId == changedGroupThreadId else {
            // not this avatar
            return
        }

        thread.reload()

        self.updateImage()
    }

    public func updateImage() {
        Logger.debug("\(self.logTag) in \(#function) updateImage")

        self.image = OWSAvatarBuilder.buildImage(thread: thread, diameter: diameter, contactsManager: contactsManager)
    }
}
