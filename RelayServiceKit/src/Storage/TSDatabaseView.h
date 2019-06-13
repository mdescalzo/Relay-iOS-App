//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import "OWSStorage.h"
#import <YapDatabase/YapDatabaseViewTransaction.h>

extern NSString *const TSInboxGroup;
extern NSString *const TSArchiveGroup;
extern NSString *const TSUnreadIncomingMessagesGroup;
extern NSString *const TSSecondaryDevicesGroup;

extern NSString *const FLPinnedGroup;
extern NSString *const FLActiveTagsGroup;
extern NSString *const FLVisibleRecipientGroup;
extern NSString *const FLAnnouncementsGroup;
extern NSString *const FLHiddenTagsGroup;
extern NSString *const FLMonitorGroup;

extern NSString *const FLTagDatabaseViewExtensionName;
extern NSString *const FLFilteredTagDatabaseViewExtensionName;

extern NSString *const TSThreadDatabaseViewExtensionName;

extern NSString *const TSMessageDatabaseViewExtensionName;
extern NSString *const TSUnreadDatabaseViewExtensionName;
extern NSString *const TSUnseenDatabaseViewExtensionName;

extern NSString *const TSSecondaryDevicesDatabaseViewExtensionName;

extern NSString *const TSLazyRestoreAttachmentsGroup;
extern NSString *const TSLazyRestoreAttachmentsDatabaseViewExtensionName;

@interface TSDatabaseView : NSObject

- (instancetype)init NS_UNAVAILABLE;

#pragma mark - Views

// Returns the "unseen" database view if it is ready;
// otherwise it returns the "unread" database view.
+ (id)unseenDatabaseViewExtension:(YapDatabaseReadTransaction *)transaction;

+ (id)threadOutgoingMessageDatabaseView:(YapDatabaseReadTransaction *)transaction;

+ (id)threadSpecialMessagesDatabaseView:(YapDatabaseReadTransaction *)transaction;

#pragma mark - Registration

+ (void)registerCrossProcessNotifier:(nonnull OWSStorage *)storage;

// This method must be called _AFTER_ asyncRegisterThreadInteractionsDatabaseView.
+ (void)asyncRegisterThreadDatabaseView:(nonnull OWSStorage *)storage;

+ (void)asyncRegisterThreadInteractionsDatabaseView:(nonnull OWSStorage *)storage;
+ (void)asyncRegisterThreadOutgoingMessagesDatabaseView:(nonnull OWSStorage *)storage;

// Instances of OWSReadTracking for wasRead is NO and shouldAffectUnreadCounts is YES.
//
// Should be used for "unread message counts".
+ (void)asyncRegisterUnreadDatabaseView:(nonnull OWSStorage *)storage;

// Should be used for "unread indicator".
//
// Instances of OWSReadTracking for wasRead is NO.
+ (void)asyncRegisterUnseenDatabaseView:(nonnull OWSStorage *)storage;

+ (void)asyncRegisterThreadSpecialMessagesDatabaseView:(nonnull OWSStorage *)storage;

+ (void)asyncRegisterSecondaryDevicesDatabaseView:(nonnull OWSStorage *)storage;

+ (void)asyncRegisterLazyRestoreAttachmentsDatabaseView:(nonnull OWSStorage *)storage
                                             completion:(nullable dispatch_block_t)completion;

// Forsta Additions
+(void)registerTagDatabaseView:(nonnull OWSStorage *)storage;
+(void)reregisterMessageDatabaseViewWithName:(nonnull NSString *)viewName
                                     storage:(nonnull OWSStorage *)storage;

@end
