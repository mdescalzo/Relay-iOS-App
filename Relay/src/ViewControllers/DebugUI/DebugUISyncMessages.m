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
//        [OWSTableItem itemWithTitle:@"Send Contacts Sync Message"
//                        actionBlock:^{
//                            [DebugUISyncMessages sendContactsSyncMessage];
//                        }],
//        [OWSTableItem itemWithTitle:@"Send Groups Sync Message"
//                        actionBlock:^{
//                            [DebugUISyncMessages sendGroupSyncMessage];
//                        }],
//        [OWSTableItem itemWithTitle:@"Send Blocklist Sync Message"
//                        actionBlock:^{
//                            [DebugUISyncMessages sendBlockListSyncMessage];
//                        }],
//        [OWSTableItem itemWithTitle:@"Send Configuration Sync Message"
//                        actionBlock:^{
//                            [DebugUISyncMessages sendConfigurationSyncMessage];
//                        }],
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

+ (OWSProfileManager *)profileManager
{
    return [OWSProfileManager sharedManager];
}

+ (YapDatabaseConnection *)dbConnection
{
    return [OWSPrimaryStorage.sharedManager newDatabaseConnection];
}

@end

NS_ASSUME_NONNULL_END
