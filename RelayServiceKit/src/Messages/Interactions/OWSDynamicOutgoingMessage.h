//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import "TSOutgoingMessage.h"

NS_ASSUME_NONNULL_BEGIN

@class OWSSignalServiceProtosDataMessageBuilder;
@class SignalRecipient;

typedef NSData *_Nonnull (^DynamicOutgoingMessageBlock)(RelayRecipient *);

@interface OWSDynamicOutgoingMessage : TSOutgoingMessage

- (instancetype)initOutgoingMessageWithTimestamp:(uint64_t)timestamp
                                        inThread:(nullable TSThread *)thread
                                     messageBody:(nullable NSString *)body
                                   attachmentIds:(NSArray<NSString *> *)attachmentIds
                                expiresInSeconds:(uint32_t)expiresInSeconds
                                 expireStartedAt:(uint64_t)expireStartedAt
                                  isVoiceMessage:(BOOL)isVoiceMessage
                                groupMetaMessage:(TSGroupMetaMessage)groupMetaMessage
                                   quotedMessage:(nullable TSQuotedMessage *)quotedMessage NS_UNAVAILABLE;

- (instancetype)initWithPlainTextDataBlock:(DynamicOutgoingMessageBlock)block thread:(nullable TSThread *)thread;
- (instancetype)initWithPlainTextDataBlock:(DynamicOutgoingMessageBlock)block
                                 timestamp:(uint64_t)timestamp
                                    thread:(nullable TSThread *)thread;

@end

NS_ASSUME_NONNULL_END
