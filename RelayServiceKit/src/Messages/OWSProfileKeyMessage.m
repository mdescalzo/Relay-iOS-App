//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import "OWSProfileKeyMessage.h"
#import "OWSSignalServiceProtos.pb.h"
#import "ProfileManagerProtocol.h"
#import "ProtoBuf+OWS.h"
#import "TextSecureKitEnv.h"

NS_ASSUME_NONNULL_BEGIN

@implementation OWSProfileKeyMessage

- (instancetype)initWithTimestamp:(uint64_t)timestamp inThread:(nullable TSThread *)thread
{
    return [super initOutgoingMessageWithTimestamp:timestamp
                                          inThread:thread
                                       messageBody:nil
                                     attachmentIds:[NSMutableArray new]
                                  expiresInSeconds:0
                                   expireStartedAt:0
                                    isVoiceMessage:NO
                                     quotedMessage:nil];
}

- (nullable instancetype)initWithCoder:(NSCoder *)coder
{
    return [super initWithCoder:coder];
}

- (BOOL)shouldBeSaved
{
    return NO;
}

- (BOOL)shouldSyncTranscript
{
    return NO;
}

- (OWSSignalServiceProtosDataMessage *)buildDataMessage:(NSString *_Nullable)recipientId
{
    OWSAssertDebug(self.thread);
    
    OWSSignalServiceProtosDataMessageBuilder *builder = [self dataMessageBuilder];
    [builder setTimestamp:self.timestamp];
    [builder addLocalProfileKey];
    [builder setFlags:OWSSignalServiceProtosDataMessageFlagsProfileKeyUpdate];
    
    if (recipientId.length > 0) {
        // Once we've shared our profile key with a user (perhaps due to being
        // a member of a whitelisted group), make sure they're whitelisted.
        id<ProfileManagerProtocol> profileManager = [TextSecureKitEnv sharedEnv].profileManager;
        [profileManager addUserToProfileWhitelist:recipientId];
    }

    return [builder build];
}

@end

NS_ASSUME_NONNULL_END
