//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import "DebugUISyncMessages.h"
#import "DebugUIContacts.h"
#import "OWSTableViewController.h"
#import "Relay-Swift.h"
#import "ThreadUtil.h"
#import <RelayMessaging/Environment.h>

@import RelayServiceKit;
@import SignalCoreKit;
@import AxolotlKit;

NS_ASSUME_NONNULL_BEGIN

@implementation DebugUISyncMessages

#pragma mark - Factory Methods

- (NSString *)name
{
    return @"Sync Messages";
}

- (nullable OWSTableSection *)sectionForThread:(nullable TSThread *)thread
{
    NSArray<OWSTableItem *> *items = @[
        [OWSTableItem itemWithTitle:@"Send Contacts Sync Message"
                        actionBlock:^{
                            [DebugUISyncMessages sendContactsSyncMessage];
                        }],
        [OWSTableItem itemWithTitle:@"Send Groups Sync Message"
                        actionBlock:^{
                            [DebugUISyncMessages sendGroupSyncMessage];
                        }],
        [OWSTableItem itemWithTitle:@"Send Blocklist Sync Message"
                        actionBlock:^{
                            [DebugUISyncMessages sendBlockListSyncMessage];
                        }],
        [OWSTableItem itemWithTitle:@"Send Configuration Sync Message"
                        actionBlock:^{
                            [DebugUISyncMessages sendConfigurationSyncMessage];
                        }],
    ];
    return [OWSTableSection sectionWithTitle:self.name items:items];
}

+ (MessageSender *)messageSender
{
    return [Environment current].messageSender;
}

+ (FLContactsManager *)contactsManager
{
    return [Environment current].contactsManager;
}

+ (OWSIdentityManager *)identityManager
{
    return [OWSIdentityManager sharedManager];
}

+ (OWSBlockingManager *)blockingManager
{
    return [OWSBlockingManager sharedManager];
}

+ (OWSProfileManager *)profileManager
{
    return [OWSProfileManager sharedManager];
}

+ (YapDatabaseConnection *)dbConnection
{
    return [OWSPrimaryStorage.sharedManager newDatabaseConnection];
}

+ (void)sendContactsSyncMessage
{
    // TODO: Replace with control message functionality
//    OWSSyncContactsMessage *syncContactsMessage =
//        [[OWSSyncContactsMessage alloc] initWithSignalAccounts:self.contactsManager.signalAccounts
//                                               identityManager:self.identityManager
//                                                profileManager:self.profileManager];
//    __block DataSource *dataSource;
//    [self.dbConnection readWriteWithBlock:^(YapDatabaseReadWriteTransaction *_Nonnull transaction) {
//        dataSource = [DataSourceValue
//            dataSourceWithSyncMessageData:[syncContactsMessage
//                                              buildPlainTextAttachmentDataWithTransaction:transaction]];
//    }];
//
//    [self.messageSender enqueueTemporaryAttachment:dataSource
//        contentType:OWSMimeTypeApplicationOctetStream
//        inMessage:syncContactsMessage
//        success:^{
//            DDLogInfo(@"%@ Successfully sent Contacts response syncMessage.", self.logTag);
//        }
//        failure:^(NSError *error) {
//            DDLogError(@"%@ Failed to send Contacts response syncMessage with error: %@", self.logTag, error);
//        }];
}

+ (void)sendGroupSyncMessage
{
    // TODO: Replace with control message send
//    OWSSyncGroupsMessage *syncGroupsMessage = [[OWSSyncGroupsMessage alloc] init];
//    __block DataSource *dataSource;
//    [self.dbConnection readWithBlock:^(YapDatabaseReadTransaction *transaction) {
//        dataSource = [DataSourceValue
//            dataSourceWithSyncMessageData:[syncGroupsMessage buildPlainTextAttachmentDataWithTransaction:transaction]];
//    }];
//    [self.messageSender enqueueTemporaryAttachment:dataSource
//        contentType:OWSMimeTypeApplicationOctetStream
//        inMessage:syncGroupsMessage
//        success:^{
//            DDLogInfo(@"%@ Successfully sent Groups response syncMessage.", self.logTag);
//        }
//        failure:^(NSError *error) {
//            DDLogError(@"%@ Failed to send Groups response syncMessage with error: %@", self.logTag, error);
//        }];
}

+ (void)sendBlockListSyncMessage
{
    [self.blockingManager syncBlockedPhoneNumbers];
}

+ (void)sendConfigurationSyncMessage
{
    DDLogDebug(@"Called unimplemented method: sendConfigurationSyncMessage");
//    __block BOOL areReadReceiptsEnabled;
//    [self.dbConnection readWithBlock:^(YapDatabaseReadTransaction *transaction) {
//        areReadReceiptsEnabled =
//            [[OWSReadReceiptManager sharedManager] areReadReceiptsEnabledWithTransaction:transaction];
//    }];
//
//    OWSSyncConfigurationMessage *syncConfigurationMessage =
//        [[OWSSyncConfigurationMessage alloc] initWithReadReceiptsEnabled:areReadReceiptsEnabled];
//    [self.messageSender enqueueMessage:syncConfigurationMessage
//        success:^{
//            DDLogInfo(@"%@ Successfully sent Configuration response syncMessage.", self.logTag);
//        }
//        failure:^(NSError *error) {
//            DDLogError(@"%@ Failed to send Configuration response syncMessage with error: %@", self.logTag, error);
//        }];
}

@end

NS_ASSUME_NONNULL_END
