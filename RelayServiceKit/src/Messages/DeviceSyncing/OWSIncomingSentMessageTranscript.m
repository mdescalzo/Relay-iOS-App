//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import "OWSIncomingSentMessageTranscript.h"
#import "OWSContact.h"
#import "OWSMessageManager.h"
#import "OWSPrimaryStorage.h"
#import "OWSSignalServiceProtos.pb.h"
#import "TSOutgoingMessage.h"
#import "TSQuotedMessage.h"
#import "TSThread.h"

NS_ASSUME_NONNULL_BEGIN

@implementation OWSIncomingSentMessageTranscript

- (instancetype)initWithProto:(OWSSignalServiceProtosSyncMessageSent *)sentProto
                 sourceDevice:(UInt32)sourceDevice
                     threadId:(NSString *)threadId
                  transaction:(YapDatabaseReadWriteTransaction *)transaction
{
    self = [super init];
    if (!self) {
        return self;
    }

    _dataMessage = sentProto.message;
    _sourceDevice = sourceDevice;
    _recipientId = sentProto.destination;
    _timestamp = sentProto.timestamp;
    _expirationStartedAt = sentProto.expirationStartTimestamp;
    _expirationDuration = sentProto.message.expireTimer;
    _body = _dataMessage.body;
    _thread = [TSThread getOrCreateThreadWithId:threadId transaction:transaction];
    _isExpirationTimerUpdate = (_dataMessage.flags & OWSSignalServiceProtosDataMessageFlagsExpirationTimerUpdate) != 0;
    _isEndSessionMessage = (_dataMessage.flags & OWSSignalServiceProtosDataMessageFlagsEndSession) != 0;

    return self;
}

- (NSArray<OWSSignalServiceProtosAttachmentPointer *> *)attachmentPointerProtos
{
    if (self.isGroupUpdate && self.dataMessage.group.hasAvatar) {
        return @[ self.dataMessage.group.avatar ];
    } else {
        return self.dataMessage.attachments;
    }
}

@end

NS_ASSUME_NONNULL_END
