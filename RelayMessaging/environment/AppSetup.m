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

@import RelayStorage
@import SignalCoreKit

NS_ASSUME_NONNULL_BEGIN

@implementation AppSetup

+ (void)setupEnvironmentWithCallMessageHandlerBlock:(CallMessageHandlerBlock)callMessageHandlerBlock
                         notificationsProtocolBlock:(NotificationsManagerBlock)notificationsManagerBlock
                                migrationCompletion:(dispatch_block_t)migrationCompletion
{
    OWSAssertDebug(callMessageHandlerBlock);
    OWSAssertDebug(notificationsManagerBlock);
    OWSAssertDebug(migrationCompletion);

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

    });
}

@end

NS_ASSUME_NONNULL_END
