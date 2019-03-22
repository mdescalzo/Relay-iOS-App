//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import "OWSReadReceiptsForSenderMessage.h"
#import "NSDate+OWS.h"
#import "OWSSignalServiceProtos.pb.h"
//#import "SignalRecipient.h"
#import <RelayServiceKit/RelayServiceKit-Swift.h>


NS_ASSUME_NONNULL_BEGIN

@interface OWSReadReceiptsForSenderMessage ()

@property (nonatomic, readonly) NSArray<NSNumber *> *messageTimestamps;

@end

#pragma mark -

@implementation OWSReadReceiptsForSenderMessage

- (instancetype)initWithThread:(nullable TSThread *)thread messageTimestamps:(NSArray<NSNumber *> *)messageTimestamps
{
    self = [super initOutgoingMessageWithTimestamp:[NSDate ows_millisecondTimeStamp]
                                          inThread:thread
                                       messageBody:nil
                                     attachmentIds:[NSMutableArray new]
                                  expiresInSeconds:0
                                   expireStartedAt:0
                                    isVoiceMessage:NO
                                     quotedMessage:nil];
    if (!self) {
        return self;
    }

    _messageTimestamps = [messageTimestamps copy];
    self.messageType = FLMessageTypeReceiptKey;

    return self;
}

#pragma mark - TSOutgoingMessage overrides

- (BOOL)shouldSyncTranscript
{
    return NO;
}

- (BOOL)isSilent
{
    // Avoid "phantom messages" for "recipient read receipts".

    return YES;
}

- (NSData *)buildPlainTextData:(RelayRecipient *)recipient
{
    OWSAssert(recipient);

    OWSSignalServiceProtosContentBuilder *contentBuilder = [OWSSignalServiceProtosContentBuilder new];
    [contentBuilder setReceiptMessage:[self buildReceiptMessage:recipient.uniqueId]];
    return [[contentBuilder build] data];
}

- (OWSSignalServiceProtosReceiptMessage *)buildReceiptMessage:(NSString *)recipientId
{
    OWSSignalServiceProtosReceiptMessageBuilder *builder = [OWSSignalServiceProtosReceiptMessageBuilder new];

    [builder setType:OWSSignalServiceProtosReceiptMessageTypeRead];
    OWSAssert(self.messageTimestamps.count > 0);
    for (NSNumber *messageTimestamp in self.messageTimestamps) {
        [builder addTimestamp:[messageTimestamp unsignedLongLongValue]];
    }

    return [builder build];
}

#pragma mark - TSYapDatabaseObject overrides

- (BOOL)shouldBeSaved
{
    return NO;
}

- (NSString *)debugDescription
{
    return [NSString stringWithFormat:@"%@ with message timestamps: %lu", self.logTag, (unsigned long)self.messageTimestamps.count];
}

@end

NS_ASSUME_NONNULL_END
