//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import "OWS109OutgoingMessageState.h"
#import <RelayServiceKit/OWSPrimaryStorage.h>
#import <RelayServiceKit/TSOutgoingMessage.h>
#import <YapDatabase/YapDatabaseTransaction.h>

NS_ASSUME_NONNULL_BEGIN

// Increment a similar constant for every future DBMigration
static NSString *const OWS109OutgoingMessageStateMigrationId = @"109";

@implementation OWS109OutgoingMessageState

+ (NSString *)migrationId
{
    return OWS109OutgoingMessageStateMigrationId;
}

// Override parent migration
- (void)runUpWithCompletion:(OWSDatabaseMigrationCompletion)completion
{
    OWSAssertDebug(completion);


    OWSDatabaseConnection *dbConnection = (OWSDatabaseConnection *)self.primaryStorage.newDatabaseConnection;

    [self resaveDBCollection:TSOutgoingMessage.collection
        filter:^(id entity) {
            return [entity isKindOfClass:[TSOutgoingMessage class]];
        }
        dbConnection:dbConnection
        completion:^{
            DDLogInfo(@"Completed migration %@", self.uniqueId);

            [self save];

            completion();
        }];
}

@end

NS_ASSUME_NONNULL_END
