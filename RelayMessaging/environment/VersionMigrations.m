//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import "VersionMigrations.h"
#import "Environment.h"
#import "SignalApp.h"
#import "LockInteractionController.h"
#import "OWSDatabaseMigrationRunner.h"
#import "SignalKeyingStorage.h"
#import "OWSNavigationController.h"

@import RelayServiceKit;
@import YapDatabase;

NS_ASSUME_NONNULL_BEGIN

#define NEEDS_TO_REGISTER_PUSH_KEY @"Register For Push"
#define NEEDS_TO_REGISTER_ATTRIBUTES @"Register Attributes"

@interface SignalKeyingStorage (VersionMigrations)

+ (void)storeString:(NSString *)string forKey:(NSString *)key;
+ (void)storeData:(NSData *)data forKey:(NSString *)key;

@end

@implementation VersionMigrations

#pragma mark Utility methods

+ (void)performUpdateCheckWithCompletion:(VersionMigrationCompletion)completion
{
    DDLogInfo(@"%@ %s", self.logTag, __PRETTY_FUNCTION__);

    // performUpdateCheck must be invoked after Environment has been initialized because
    // upgrade process may depend on Environment.
    OWSAssertDebug([Environment current]);
    OWSAssertDebug(completion);

    NSString *previousVersion = AppVersion.sharedInstance.lastAppVersion;
    NSString *currentVersion = AppVersion.sharedInstance.currentAppVersion;

    DDLogInfo(@"%@ Checking migrations. currentVersion: %@, lastRanVersion: %@",
        self.logTag,
        currentVersion,
        previousVersion);

    if (!previousVersion) {
        DDLogInfo(@"No previous version found. Probably first launch since install - nothing to migrate.");
        OWSDatabaseMigrationRunner *runner =
            [[OWSDatabaseMigrationRunner alloc] initWithPrimaryStorage:[OWSPrimaryStorage sharedManager]];
        [runner assumeAllExistingMigrationsRun];
        dispatch_async(dispatch_get_main_queue(), ^{
            completion();
        });
        return;
    }
    
    // Message touch to reindex due to search bugs
    if ([self isVersion:previousVersion lessThan:@"2.0.4"]) {
        DDLogInfo(@"Touching messages in database.");
        [OWSPrimaryStorage.dbReadWriteConnection asyncReadWriteWithBlock:^(YapDatabaseReadWriteTransaction * _Nonnull transaction) {
            for (TSIncomingMessage *message in [TSIncomingMessage allObjectsInCollection]) {
                [message touchWithTransaction:transaction];
            }
            for (TSOutgoingMessage *message in [TSOutgoingMessage allObjectsInCollection]) {
                [message touchWithTransaction:transaction];
            }
        }];
    }

    if ([self isVersion:previousVersion lessThan:@"2.0.1"]) {
        DDLogInfo(@"Wiping thread images due to assignment bug in 2.0.0");
        for (TSThread *thread in [TSThread allObjectsInCollection]) {
            if (thread.image != nil) {
                DDLogInfo(@"Found one!");
                thread.image = nil;
                [thread save];
            }
        }
    }
    
    if ([self isVersion:previousVersion lessThan:@"2.0.0"]) {
        DDLogError(@"Migrating from version 1.x.x.  Wiping database");
        // Not translating these as so few are affected.
        UIAlertController *alertController = [UIAlertController
            alertControllerWithTitle:nil
                             message:
                                 @"Sorry, your message database is too old for us to update."
                      preferredStyle:UIAlertControllerStyleAlert];

        [alertController addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"OK", nil)
                                                            style:UIAlertActionStyleDefault
                                                          handler:^(UIAlertAction *_Nonnull action) {
                                                              // TODO: Post notification which trips the return to reg view
                                                              [NSNotificationCenter.defaultCenter postNotificationName:FLRelayWipeAndReturnToRegistrationNotification object:nil];
                                                          }]];

        [CurrentAppContext().frontmostViewController presentViewController:alertController animated:YES completion:nil];
        return;
    }
    
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [[[OWSDatabaseMigrationRunner alloc] initWithPrimaryStorage:[OWSPrimaryStorage sharedManager]]
            runAllOutstandingWithCompletion:completion];
    });
}

+ (BOOL)isVersion:(NSString *)thisVersionString
          atLeast:(NSString *)openLowerBoundVersionString
      andLessThan:(NSString *)closedUpperBoundVersionString
{
    return [self isVersion:thisVersionString atLeast:openLowerBoundVersionString] &&
        [self isVersion:thisVersionString lessThan:closedUpperBoundVersionString];
}

+ (BOOL)isVersion:(NSString *)thisVersionString atLeast:(NSString *)thatVersionString
{
    return [thisVersionString compare:thatVersionString options:NSNumericSearch] != NSOrderedAscending;
}

+ (BOOL)isVersion:(NSString *)thisVersionString lessThan:(NSString *)thatVersionString
{
    return [thisVersionString compare:thatVersionString options:NSNumericSearch] == NSOrderedAscending;
}

// MARK: - Forsta migrations
+(void)nukeAndPaveDBContents
{
}

#pragma mark Upgrading to 2.1 - Removing video cache folder

+ (void)clearVideoCache
{
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *basePath = ([paths count] > 0) ? [paths objectAtIndex:0] : nil;
    basePath = [basePath stringByAppendingPathComponent:@"videos"];

    NSError *error;
    if ([[NSFileManager defaultManager] fileExistsAtPath:basePath]) {
        [NSFileManager.defaultManager removeItemAtPath:basePath error:&error];
    }

    if (error) {
        DDLogError(
            @"An error occured while removing the videos cache folder from old location: %@", error.debugDescription);
    }
}

#pragma mark Upgrading to 2.1.3 - Adding VOIP flag on TS Server

+ (void)blockingAttributesUpdate
{
    LIControllerBlockingOperation blockingOperation = ^BOOL(void) {
        [[NSUserDefaults appUserDefaults] setObject:@YES forKey:NEEDS_TO_REGISTER_ATTRIBUTES];

        __block dispatch_semaphore_t sema = dispatch_semaphore_create(0);

        __block BOOL success;

        TSRequest *request = [OWSRequestFactory updateAttributesRequestWithManualMessageFetching:NO];
        [[TSNetworkManager sharedManager] makeRequest:request
            success:^(NSURLSessionDataTask *task, id responseObject) {
                success = YES;
                dispatch_semaphore_signal(sema);
            }
            failure:^(NSURLSessionDataTask *task, NSError *error) {
                success = NO;
                DDLogError(@"Updating attributess failed with error: %@", error.description);
                dispatch_semaphore_signal(sema);
            }];


        dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);

        return success;
    };

    LIControllerRetryBlock retryBlock = [LockInteractionController defaultNetworkRetry];

    [LockInteractionController performBlock:blockingOperation
                            completionBlock:^{
                                [[NSUserDefaults appUserDefaults] removeObjectForKey:NEEDS_TO_REGISTER_ATTRIBUTES];
                                DDLogWarn(@"Successfully updated attributes.");
                            }
                                 retryBlock:retryBlock
                                usesNetwork:YES];
}

#pragma mark Upgrading to 2.3.0

// We removed bloom filter contact discovery. Clean up any local bloom filter data.
+ (void)clearBloomFilterCache
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *cachesDir = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString *bloomFilterPath = [[cachesDir objectAtIndex:0] stringByAppendingPathComponent:@"bloomfilter"];

    if ([fm fileExistsAtPath:bloomFilterPath]) {
        NSError *deleteError;
        if ([fm removeItemAtPath:bloomFilterPath error:&deleteError]) {
            DDLogInfo(@"Successfully removed bloom filter cache.");
            [OWSPrimaryStorage.dbReadWriteConnection
                readWriteWithBlock:^(YapDatabaseReadWriteTransaction *_Nonnull transaction) {
                    [transaction removeAllObjectsInCollection:@"TSRecipient"];
                }];
            DDLogInfo(@"Removed all TSRecipient records - will be replaced by SignalRecipients at next address sync.");
        } else {
            DDLogError(@"Failed to remove bloom filter cache with error: %@", deleteError.localizedDescription);
        }
    } else {
        DDLogDebug(@"No bloom filter cache to remove.");
    }
}

@end

NS_ASSUME_NONNULL_END
