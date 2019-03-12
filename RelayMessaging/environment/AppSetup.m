//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import "AppSetup.h"
#import "Environment.h"
#import "Release.h"
#import "VersionMigrations.h"
#import <RelayMessaging/OWSDatabaseMigration.h>
#import <RelayMessaging/OWSProfileManager.h>
#import <RelayMessaging/RelayMessaging-Swift.h>

@import RelayServiceKit;
@import AxolotlKit;

NS_ASSUME_NONNULL_BEGIN

@implementation AppSetup

+ (void)setupEnvironmentWithCallMessageHandlerBlock:(CallMessageHandlerBlock)callMessageHandlerBlock
                         notificationsProtocolBlock:(NotificationsManagerBlock)notificationsManagerBlock
                                migrationCompletion:(dispatch_block_t)migrationCompletion
{
    OWSAssert(callMessageHandlerBlock);
    OWSAssert(notificationsManagerBlock);
    OWSAssert(migrationCompletion);

    __block OWSBackgroundTask *_Nullable backgroundTask =
        [OWSBackgroundTask backgroundTaskWithLabelStr:__PRETTY_FUNCTION__];

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // Order matters here.
        [[OWSBackgroundTaskManager sharedManager] observeNotifications];

        [Environment setCurrent:[Release releaseEnvironment]];

        id<FLCallMessageHandler> callMessageHandler = callMessageHandlerBlock();
        id<NotificationsProtocol> notificationsManager = notificationsManagerBlock();

        TextSecureKitEnv *sharedEnv =
            [[TextSecureKitEnv alloc] initWithCallMessageHandler:callMessageHandler
                                                 contactsManager:[Environment current].contactsManager
                                                   messageSender:[Environment current].messageSender
                                            notificationsManager:notificationsManager
                                                  profileManager:OWSProfileManager.sharedManager];
        [TextSecureKitEnv setSharedEnv:sharedEnv];

        // Register renamed classes.
        [NSKeyedUnarchiver setClass:[OWSUserProfile class] forClassName:[OWSUserProfile collection]];
        [NSKeyedUnarchiver setClass:[OWSDatabaseMigration class] forClassName:[OWSDatabaseMigration collection]];

        [OWSStorage registerExtensionsWithMigrationBlock:^() {
            // Don't start database migrations until storage is ready.
            [VersionMigrations performUpdateCheckWithCompletion:^() {
                OWSAssertIsOnMainThread();

                migrationCompletion();

                backgroundTask = nil;
            }];
        }];
    });
}

@end

NS_ASSUME_NONNULL_END
