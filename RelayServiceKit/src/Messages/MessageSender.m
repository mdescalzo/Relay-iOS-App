//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import "MessageSender.h"
#import "AppContext.h"
#import "NSData+keyVersionByte.h"
#import "NSData+messagePadding.h"
#import "NSDate+OWS.h"
#import "NSError+MessageSending.h"
#import "OWSBackgroundTask.h"
#import "OWSBlockingManager.h"
#import "OWSContact.h"
#import "OWSDevice.h"
#import "OWSDisappearingMessagesJob.h"
#import "OWSError.h"
#import "OWSIdentityManager.h"
#import "OWSMessageServiceParams.h"
#import "OWSOperation.h"
#import "OWSOutgoingSentMessageTranscript.h"
#import "OWSOutgoingSyncMessage.h"
#import "OWSPrimaryStorage+PreKeyStore.h"
#import "OWSPrimaryStorage+SignedPreKeyStore.h"
#import "OWSPrimaryStorage+sessionStore.h"
#import "OWSPrimaryStorage.h"
#import "OWSRequestFactory.h"
#import "OWSUploadOperation.h"
#import "PreKeyBundle+jsonDict.h"
#import "TSAccountManager.h"
#import "TSAttachmentStream.h"
#import "TSIncomingMessage.h"
#import "TSInfoMessage.h"
#import "TSInvalidIdentityKeySendingErrorMessage.h"
#import "TSNetworkManager.h"
#import "TSOutgoingMessage.h"
#import "TSPreKeyManager.h"
#import "TSQuotedMessage.h"
#import "TSSocketManager.h"
#import "TSThread.h"
#import "Threading.h"
#import "SSKAsserts.h"
#import <RelayServiceKit/RelayServiceKit-Swift.h>


@import PromiseKit;
@import AxolotlKit;

NS_ASSUME_NONNULL_BEGIN

const NSUInteger kOversizeTextMessageSizeThreshold = NSUIntegerMax; //2 * 1024;

void AssertIsOnSendingQueue()
{
#ifdef DEBUG
    if (@available(iOS 10.0, *)) {
        dispatch_assert_queue([OWSDispatch sendingQueue]);
    } // else, skip assert as it's a development convenience.
#endif
}

#pragma mark -

/**
 * OWSSendMessageOperation encapsulates all the work associated with sending a message, e.g. uploading attachments,
 * getting proper keys, and retrying upon failure.
 *
 * Used by `MessageSender` to serialize message sending, ensuring that messages are emitted in the order they
 * were sent.
 */
@interface OWSSendMessageOperation : OWSOperation

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithMessage:(TSOutgoingMessage *)message
                  messageSender:(MessageSender *)messageSender
                   dbConnection:(YapDatabaseConnection *)dbConnection
                        success:(void (^)(void))aSuccessHandler
                        failure:(void (^)(NSError * error))aFailureHandler NS_DESIGNATED_INITIALIZER;

@end

#pragma mark -

@interface MessageSender (OWSSendMessageOperation)

- (void)sendMessageToService:(TSOutgoingMessage *)message
                     success:(void (^)(void))successHandler
                     failure:(RetryableFailureHandler)failureHandler;

@end

#pragma mark -

@interface OWSSendMessageOperation ()

@property (nonatomic, readonly) TSOutgoingMessage *message;
@property (nonatomic, readonly) MessageSender *messageSender;
@property (nonatomic, readonly) YapDatabaseConnection *dbConnection;
@property (nonatomic, readonly) void (^successHandler)(void);
@property (nonatomic, readonly) void (^failureHandler)(NSError * error);

@end

#pragma mark -

@implementation OWSSendMessageOperation

- (instancetype)initWithMessage:(TSOutgoingMessage *)message
                  messageSender:(MessageSender *)messageSender
                   dbConnection:(YapDatabaseConnection *)dbConnection
                        success:(void (^)(void))successHandler
                        failure:(void (^)(NSError * error))failureHandler
{
    self = [super init];
    if (!self) {
        return self;
    }
    
    self.remainingRetries = 6;
    _message = message;
    _messageSender = messageSender;
    _dbConnection = dbConnection;
    _successHandler = successHandler;
    _failureHandler = failureHandler;
    
    return self;
}

#pragma mark - OWSOperation overrides

- (nullable NSError *)checkForPreconditionError
{
    NSError *_Nullable error = [super checkForPreconditionError];
    if (error) {
        return error;
    }
    
    // Sanity check preconditions
    if (self.message.hasAttachments) {
        [self.dbConnection readWithBlock:^(YapDatabaseReadTransaction * transaction) {
            TSAttachmentStream *attachmentStream
            = (TSAttachmentStream *)[self.message attachmentWithTransaction:transaction];
            OWSAssert(attachmentStream);
            OWSAssert([attachmentStream isKindOfClass:[TSAttachmentStream class]]);
            OWSAssert(attachmentStream.serverId);
            OWSAssert(attachmentStream.isUploaded);
        }];
    }
    
    return nil;
}

- (void)run
{
    // If the message has been deleted, abort send.
    if (self.message.shouldBeSaved && ![TSOutgoingMessage fetchObjectWithUniqueID:self.message.uniqueId]) {
        DDLogInfo(@"%@ aborting message send; message deleted.", self.logTag);
        NSError *error = OWSErrorWithCodeDescription(
                                                     OWSErrorCodeMessageDeletedBeforeSent, @"Message was deleted before it could be sent.");
        error.isFatal = YES;
        [self reportError:error];
        return;
    }
    
    [self.messageSender sendMessageToService:self.message
                                     success:^{
                                         [self reportSuccess];
                                     }
                                     failure:^(NSError *error) {
                                         [self reportError:error];
                                     }];
}

- (void)didSucceed
{
    if (self.message.messageState != TSOutgoingMessageStateSent) {
        OWSFailDebug(@"%@ unexpected message status: %@", self.logTag, self.message.statusDescription);
    }
    
    self.successHandler();
}

- (void)didFailWithError:(NSError *)error
{
    [self.message updateWithSendingError:error];
    
    DDLogDebug(@"%@ failed with error: %@", self.logTag, error);
    self.failureHandler(error);
}

@end

int const MessageSenderRetryAttempts = 3;
NSString *const MessageSenderInvalidDeviceException = @"InvalidDeviceException";
NSString *const MessageSenderRateLimitedException = @"RateLimitedException";

@interface MessageSender ()

@property (nonatomic, readonly) TSNetworkManager *networkManager;
@property (nonatomic, readonly) OWSPrimaryStorage *primaryStorage;
@property (nonatomic, readonly) OWSBlockingManager *blockingManager;
@property (nonatomic, readonly) YapDatabaseConnection *dbConnection;
@property (nonatomic, readonly) id<ContactsManagerProtocol> contactsManager;
@property (atomic, readonly) NSMutableDictionary<NSString *, NSOperationQueue *> *sendingQueueMap;

@end

@implementation MessageSender

- (instancetype)initWithNetworkManager:(TSNetworkManager *)networkManager
                        primaryStorage:(OWSPrimaryStorage *)primaryStorage
                       contactsManager:(id<ContactsManagerProtocol>)contactsManager
{
    self = [super init];
    if (!self) {
        return self;
    }
    
    _networkManager = networkManager;
    _primaryStorage = primaryStorage;
    _contactsManager = contactsManager;
    _sendingQueueMap = [NSMutableDictionary new];
    _dbConnection = primaryStorage.newDatabaseConnection;
    
    OWSSingletonAssert();
    
    return self;
}

- (void)setBlockingManager:(OWSBlockingManager *)blockingManager
{
    OWSAssert(blockingManager);
    OWSAssert(!_blockingManager);
    
    _blockingManager = blockingManager;
}

- (NSOperationQueue *)sendingQueueForMessage:(TSOutgoingMessage *)message
{
    OWSAssert(message);
    
    
    NSString *kDefaultQueueKey = @"kDefaultQueueKey";
    NSString *queueKey = message.uniqueThreadId ?: kDefaultQueueKey;
    OWSAssert(queueKey.length > 0);
    
    if ([kDefaultQueueKey isEqualToString:queueKey]) {
        // when do we get here?
        DDLogDebug(@"%@ using default message queue", self.logTag);
    }
    
    @synchronized(self)
    {
        NSOperationQueue *sendingQueue = self.sendingQueueMap[queueKey];
        
        if (!sendingQueue) {
            sendingQueue = [NSOperationQueue new];
            sendingQueue.qualityOfService = NSOperationQualityOfServiceUserInitiated;
            sendingQueue.maxConcurrentOperationCount = 1;
            
            self.sendingQueueMap[queueKey] = sendingQueue;
        }
        
        return sendingQueue;
    }
}

- (void)enqueueMessage:(TSOutgoingMessage *)message
               success:(void (^)(void))successHandler
               failure:(void (^)(NSError *error))failureHandler
{
    OWSAssert(message);
//    if (message.body.length > 0) {
//        OWSAssert([message.body lengthOfBytesUsingEncoding:NSUTF8StringEncoding] <= kOversizeTextMessageSizeThreshold);
//    }
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        
        __block NSArray<TSAttachmentStream *> *quotedThumbnailAttachments = @[];
        __block TSAttachmentStream *_Nullable contactShareAvatarAttachment;
        
        // This method will use a read/write transaction. This transaction
        // will block until any open read/write transactions are complete.
        //
        // That's key - we don't want to send any messages in response
        // to an incoming message until processing of that batch of messages
        // is complete.  For example, we wouldn't want to auto-reply to a
        // group info request before that group info request's batch was
        // finished processing.  Otherwise, we might receive a delivery
        // notice for a group update we hadn't yet saved to the db.
        //
        // So we're using YDB behavior to ensure this invariant, which is a bit
        // unorthodox.
        [self.dbConnection readWriteWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
            // make sure the body is JSON
            if (!(message.body && [NSJSONSerialization JSONObjectWithData:[message.body dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil])) {
                NSString *messageBlob = [FLCCSMJSONService blobFromMessage:message];
                message.body = messageBlob;
            }
            
            if (message.body.length == 0) {
                OWSFailDebug(@"Unexpected empty body on outbound message of class: %@", [message class]);
            }

            if (message.quotedMessage) {
                quotedThumbnailAttachments =
                [message.quotedMessage createThumbnailAttachmentsIfNecessaryWithTransaction:transaction];
            }
            
            if (message.contactShare.avatarAttachmentId != nil) {
                TSAttachment *avatarAttachment = [message.contactShare avatarAttachmentWithTransaction:transaction];
                if ([avatarAttachment isKindOfClass:[TSAttachmentStream class]]) {
                    contactShareAvatarAttachment = (TSAttachmentStream *)avatarAttachment;
                } else {
                    OWSFail(@"%@ in %s unexpected avatarAttachment: %@",
                            self.logTag,
                            __PRETTY_FUNCTION__,
                            avatarAttachment);
                }
            }
            
            // All outgoing messages should be saved at the time they are enqueued.
            [message saveWithTransaction:transaction];
            // When we start a message send, all "failed" recipients should be marked as "sending".
            [message updateWithMarkingAllUnsentRecipientsAsSendingWithTransaction:transaction];
        }];
        
        NSOperationQueue *sendingQueue = [self sendingQueueForMessage:message];
        OWSSendMessageOperation *sendMessageOperation =
        [[OWSSendMessageOperation alloc] initWithMessage:message
                                           messageSender:self
                                            dbConnection:self.dbConnection
                                                 success:successHandler
                                                 failure:failureHandler];
        
        // TODO de-dupe attachment enque logic.
        if (message.hasAttachments) {
            OWSUploadOperation *uploadAttachmentOperation =
            [[OWSUploadOperation alloc] initWithAttachmentId:message.attachmentIds.firstObject
                                                dbConnection:self.dbConnection];
            [sendMessageOperation addDependency:uploadAttachmentOperation];
            [sendingQueue addOperation:uploadAttachmentOperation];
        }
        
        // Though we currently only ever expect at most one thumbnail, the proto data model
        // suggests this could change. The logic is intended to work with multiple, but
        // if we ever actually want to send multiple, we should do more testing.
        OWSAssert(quotedThumbnailAttachments.count <= 1);
        for (TSAttachmentStream *thumbnailAttachment in quotedThumbnailAttachments) {
            OWSAssert(message.quotedMessage);
            
            OWSUploadOperation *uploadQuoteThumbnailOperation =
            [[OWSUploadOperation alloc] initWithAttachmentId:thumbnailAttachment.uniqueId
                                                dbConnection:self.dbConnection];
            
            // TODO put attachment uploads on a (lowly) concurrent queue
            [sendMessageOperation addDependency:uploadQuoteThumbnailOperation];
            [sendingQueue addOperation:uploadQuoteThumbnailOperation];
        }
        
        if (contactShareAvatarAttachment != nil) {
            OWSAssert(message.contactShare);
            OWSUploadOperation *uploadAvatarOperation =
            [[OWSUploadOperation alloc] initWithAttachmentId:contactShareAvatarAttachment.uniqueId
                                                dbConnection:self.dbConnection];
            
            // TODO put attachment uploads on a (lowly) concurrent queue
            [sendMessageOperation addDependency:uploadAvatarOperation];
            [sendingQueue addOperation:uploadAvatarOperation];
        }
        
        [sendingQueue addOperation:sendMessageOperation];
    });
}

- (void)enqueueTemporaryAttachment:(DataSource *)dataSource
                       contentType:(NSString *)contentType
                         inMessage:(TSOutgoingMessage *)message
                           success:(void (^)(void))successHandler
                           failure:(void (^)(NSError *error))failureHandler
{
    OWSAssert(dataSource);
    
    void (^successWithDeleteHandler)(void) = ^() {
        successHandler();
        
        DDLogDebug(@"%@ Removing successful temporary attachment message with attachment ids: %@",
                   self.logTag,
                   message.attachmentIds);
        [message remove];
    };
    
    void (^failureWithDeleteHandler)(NSError *error) = ^(NSError *error) {
        failureHandler(error);
        
        DDLogDebug(@"%@ Removing failed temporary attachment message with attachment ids: %@",
                   self.logTag,
                   message.attachmentIds);
        [message remove];
    };
    
    [self enqueueAttachment:dataSource
                contentType:contentType
             sourceFilename:nil
                  inMessage:message
                    success:successWithDeleteHandler
                    failure:failureWithDeleteHandler];
}

- (void)enqueueAttachment:(DataSource *)dataSource
              contentType:(NSString *)contentType
           sourceFilename:(nullable NSString *)sourceFilename
                inMessage:(TSOutgoingMessage *)message
                  success:(void (^)(void))successHandler
                  failure:(void (^)(NSError *error))failureHandler
{
    OWSAssert(dataSource);
    
    dispatch_async([OWSDispatch attachmentsQueue], ^{
        TSAttachmentStream *attachmentStream =
        [[TSAttachmentStream alloc] initWithContentType:contentType
                                              byteCount:(UInt32)dataSource.dataLength
                                         sourceFilename:sourceFilename];
        if (message.isVoiceMessage) {
            attachmentStream.attachmentType = TSAttachmentTypeVoiceMessage;
        }
        
        if (![attachmentStream writeDataSource:dataSource]) {
            NSError *error = OWSErrorMakeWriteAttachmentDataError();
            return failureHandler(error);
        }
        
        [attachmentStream save];
        [message.attachmentIds addObject:attachmentStream.uniqueId];
        if (sourceFilename) {
            message.attachmentFilenameMap[attachmentStream.uniqueId] = sourceFilename;
        }
        
        [self enqueueMessage:message success:successHandler failure:failureHandler];
    });
}

- (NSArray<RelayRecipient *> *)relayRecipientsForRecipientIds:(NSArray<NSString *> *)recipientIds
{
    OWSAssert(recipientIds);
    
    NSMutableArray<RelayRecipient *> *recipients = [NSMutableArray new];
    [self.dbConnection readWithBlock:^(YapDatabaseReadTransaction *transaction) {
        for (NSString *recipientId in recipientIds) {
            RelayRecipient *recipient =
            [RelayRecipient getOrBuildUnsavedRecipientForRecipientId:recipientId transaction:transaction];
            [recipients addObject:recipient];
        }
    }];
    return recipients;
}

- (void)sendMessageToService:(TSOutgoingMessage *)message
                     success:(void (^)(void))successHandler
                     failure:(RetryableFailureHandler)failureHandler
{
    dispatch_async([OWSDispatch sendingQueue], ^{
        TSThread *_Nullable thread = message.thread;
        
        if ([thread.participantIds containsObject:[TSAccountManager localUID]] && thread.participantIds.count == 1)
        {
            // Send to self.
            [self.dbConnection readWriteWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
                for (NSString *recipientId in message.sendingRecipientIds) {
                    [message updateWithReadRecipientId:recipientId
                                         readTimestamp:message.timestampForSorting
                                           transaction:transaction];
                }
            }];
            
            [self handleMessageSentLocally:message];
            
            successHandler();
            return;
        } else if ([message isKindOfClass:[OWSOutgoingSyncMessage class]]) {
            
            // Sync message send
            NSString *recipientContactId = [TSAccountManager localUID];
            
            // If we block a user, don't send 1:1 messages to them. The UI
            // should prevent this from occurring, but in some edge cases
            // you might, for example, have a pending outgoing message when
            // you block them.
            OWSAssert(recipientContactId.length > 0);
            if ([self.blockingManager isRecipientIdBlocked:recipientContactId]) {
                DDLogInfo(@"%@ skipping 1:1 send to blocked contact: %@", self.logTag, recipientContactId);
                NSError *error = OWSErrorMakeMessageSendFailedToBlockListError();
                // No need to retry - the user will continue to be blocked.
                [error setIsRetryable:NO];
                failureHandler(error);
                return;
            }
            
            NSArray<RelayRecipient *> *recipients =
            [self relayRecipientsForRecipientIds:@[recipientContactId]];
            OWSAssert(recipients.count == 1);
            RelayRecipient *recipient = recipients.firstObject;
            
            if (!recipient) {
                NSError *error = OWSErrorMakeFailedToSendOutgoingMessageError();
                DDLogWarn(@"recipient contact still not found after attempting lookup.");
                // No need to repeat trying to find a failure. Apart from repeatedly failing, it would also cause us to
                // print redundant error messages.
                [error setIsRetryable:NO];
                failureHandler(error);
                return;
            }
            
            [self sendMessageToService:message
                             recipient:recipient
                                thread:thread
                              attempts:MessageSenderRetryAttempts
               useWebsocketIfAvailable:YES
                               success:successHandler
                               failure:failureHandler];
        } else  {
            
            // Send to the intersection of:
            //
            // * "sending" recipients of the message.
            // * members of the group.
            //
            // I.e. try to send a message IFF:
            //
            // * The recipient was in the group when the message was first tried to be sent.
            // * The recipient is still in the group.
            // * The recipient is in the "sending" state.
            
            NSMutableSet<NSString *> *sendingRecipientIds = [NSMutableSet setWithArray:message.sendingRecipientIds];
            [sendingRecipientIds intersectSet:[NSSet setWithArray:thread.participantIds]];
            [sendingRecipientIds minusSet:[NSSet setWithArray:self.blockingManager.blockedPhoneNumbers]];
            
            // Mark skipped recipients as such.  We skip because:
            //
            // * Recipient is no longer in the group.
            // * Recipient is blocked.
            //
            // Elsewhere, we skip recipient if their account has been deactivated.
            NSMutableSet<NSString *> *obsoleteRecipientIds = [NSMutableSet setWithArray:message.sendingRecipientIds];
            [obsoleteRecipientIds minusSet:sendingRecipientIds];
            if (obsoleteRecipientIds.count > 0) {
                [self.dbConnection readWriteWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
                    for (NSString *recipientId in obsoleteRecipientIds) {
                        // Mark this recipient as "skipped".
                        [message updateWithSkippedRecipient:recipientId transaction:transaction];
                    }
                }];
            }
            
            if (sendingRecipientIds.count < 1) {
                // All recipients are already sent or can be skipped.
                successHandler();
                return;
            }
            
            NSArray<RelayRecipient *> *recipients =
            [self relayRecipientsForRecipientIds:sendingRecipientIds.allObjects];
            OWSAssert(recipients.count == sendingRecipientIds.count);
            
            [self groupSend:recipients message:message thread:thread success:^{
                // Send to any assigned thread monitors
                if (thread.monitorIds.count > 0) {
                    TSOutgoingMessage *monitorMessage = [TSOutgoingMessage outgoingMessageInThread:nil
                                                                                       messageBody:message.body
                                                                                      attachmentId:message.attachmentIds.lastObject];
                    for (NSString *monitorId in thread.monitorIds) {
                        [self sendSpecialMessage:monitorMessage
                                     recipientId:monitorId
                                        attempts:3
                                         success:^{
                                             DDLogDebug(@"Monitor send successful.");
                                             [monitorMessage removeKeepingAttachments:YES];
                                         }
                                         failure:^(NSError *error){
                                             DDLogDebug(@"Send to monitors failed.  Error: %@", error.localizedDescription);
                                             [monitorMessage removeKeepingAttachments:YES];
                                         }];
                    }
                }
                successHandler();
            }
                    failure:failureHandler];
        }
    });
}

- (void)groupSend:(NSArray<RelayRecipient *> *)recipients
          message:(TSOutgoingMessage *)message
           thread:(TSThread *)thread
          success:(void (^)(void))successHandler
          failure:(RetryableFailureHandler)failureHandler
{
    [self saveGroupMessage:message inThread:thread];
    
    NSMutableArray<AnyPromise *> *sendPromises = [NSMutableArray array];
    NSMutableArray<NSError *> *sendErrors = [NSMutableArray array];
    
    for (RelayRecipient *recipient in recipients) {
        NSString *recipientId = recipient.uniqueId;
        
        // We don't need to send the message to ourselves...
        if ([recipientId isEqualToString:[TSAccountManager localUID]]) {
            continue;
        }
        
        // ...otherwise we send.
        
        // For group sends, we're using chained promises to make the code more readable.
        AnyPromise *sendPromise = [AnyPromise promiseWithResolverBlock:^(PMKResolver resolve) {
            [self sendMessageToService:message
                             recipient:recipient
                                thread:thread
                              attempts:MessageSenderRetryAttempts
               useWebsocketIfAvailable:YES
                               success:^{
                                   // The value doesn't matter, we just need any non-NSError value.
                                   resolve(@(1));
                               }
                               failure:^(NSError *error) {
                                   @synchronized(sendErrors) {
                                       [sendErrors addObject:error];
                                   }
                                   resolve(error);
                               }];
        }];
        [sendPromises addObject:sendPromise];
    }
    
    // We use PMKJoin(), not PMKWhen(), because we don't want the
    // completion promise to execute until _all_ send promises
    // have either succeeded or failed. PMKWhen() executes as
    // soon as any of its input promises fail.
    AnyPromise *sendCompletionPromise = PMKJoin(sendPromises);
    sendCompletionPromise.then(^(id value) {
        successHandler();
    });
    sendCompletionPromise.catch(^(id failure) {
        NSError *firstRetryableError = nil;
        NSError *firstNonRetryableError = nil;
        
        NSArray<NSError *> *sendErrorsCopy;
        @synchronized(sendErrors) {
            sendErrorsCopy = [sendErrors copy];
        }
        
        for (NSError *error in sendErrorsCopy) {
            // Some errors should be ignored when sending messages
            // to groups.  See discussion on
            // NSError (MessageSender) category.
            if ([error shouldBeIgnoredForGroups]) {
                continue;
            }
            
            // Some errors should never be retried, in order to avoid
            // hitting rate limits, for example.  Unfortunately, since
            // group send retry is all-or-nothing, we need to fail
            // immediately even if some of the other recipients had
            // retryable errors.
            if ([error isFatal]) {
                failureHandler(error);
                return;
            }
            
            if ([error isRetryable] && !firstRetryableError) {
                firstRetryableError = error;
            } else if (![error isRetryable] && !firstNonRetryableError) {
                firstNonRetryableError = error;
            }
        }
        
        // If any of the group send errors are retryable, we want to retry.
        // Therefore, prefer to propagate a retryable error.
        if (firstRetryableError) {
            return failureHandler(firstRetryableError);
        } else if (firstNonRetryableError) {
            return failureHandler(firstNonRetryableError);
        } else {
            // If we only received errors that we should ignore,
            // consider this send a success, unless the message could
            // not be sent to any recipient.
            if (message.sentRecipientsCount == 0) {
                NSError *error = OWSErrorWithCodeDescription(OWSErrorCodeMessageSendNoValidRecipients,
                                                             NSLocalizedString(@"ERROR_DESCRIPTION_NO_VALID_RECIPIENTS",
                                                                               @"Error indicating that an outgoing message had no valid recipients."));
                [error setIsRetryable:NO];
                failureHandler(error);
            } else {
                successHandler();
            }
        }
    });
    [sendCompletionPromise retainUntilComplete];
}

-(void)sendControlMessage:(OutgoingControlMessage *)message
             toRecipients:(NSCountedSet<NSString *> *)recipientIds
                  success:(void (^)(void))successHandler
                  failure:(void (^)(NSError *error))failureHandler
{
    // If nothing to do, bail and call success
    if (recipientIds.count == 0) {
        DDLogDebug(@"No recipients for attempted control message send.");
        successHandler();
    } else {
        dispatch_async([OWSDispatch sendingQueue], ^{
            // Check to see if blob is already JSON
            // Convert message body to JSON blob if necessary
            if (!(message.body && [NSJSONSerialization JSONObjectWithData:[message.body dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil])) {
                NSString *messageBlob = [FLCCSMJSONService blobFromMessage:message];
                message.body = messageBlob;
            }

            if (message.body.length == 0) {
                OWSFailDebug(@"Unexpected empty body on outbound control message of class: %@", [message class]);
            }

            
            for (NSString *recipientId in recipientIds) {
                if ([recipientId isEqualToString:[TSAccountManager localUID]]) {
                    // TODO: sendSync
                    [self sendSyncTranscriptForMessage:message];
                    if (successHandler) {
                        successHandler();
                    }
                } else {
                    [self sendSpecialMessage:message
                                 recipientId:recipientId
                                    attempts:3
                                     success:^{
                                         DDLogDebug(@"Control successfully sent to: %@", recipientId);
                                         if (successHandler) {
                                             successHandler();
                                         }
                                     } failure:^(NSError * _Nonnull error) {
                                         DDLogDebug(@"Control message send failed to %@\nError: %@", recipientId, error.localizedDescription);
                                         if (failureHandler) {
                                             failureHandler(error);
                                         }
                                     }];
                }
            }
        });
    }
}

- (void)unregisteredRecipient:(RelayRecipient *)recipient
                      message:(TSOutgoingMessage *)message
                       thread:(TSThread *)thread
{
    [self.dbConnection readWriteWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
        // Mark as "skipped" group members who no longer have signal accounts.
        [message updateWithSkippedRecipient:recipient.uniqueId transaction:transaction];
        
        [RelayRecipient removeUnregisteredRecipient:recipient.uniqueId transaction:transaction];
        
        [[TSInfoMessage userNotRegisteredMessageInThread:thread recipientId:recipient.uniqueId]
         saveWithTransaction:transaction];
        
        // TODO: Should we deleteAllSessionsForContact here?
        //       If so, we'll need to avoid doing a prekey fetch every
        //       time we try to send a message to an unregistered user.
    }];
}

- (void)sendMessageToService:(TSOutgoingMessage *)message
                   recipient:(RelayRecipient *)recipient
                      thread:(nullable TSThread *)thread
                    attempts:(int)remainingAttemptsParam
     useWebsocketIfAvailable:(BOOL)useWebsocketIfAvailable
                     success:(void (^)(void))successHandler
                     failure:(RetryableFailureHandler)failureHandler
{
    OWSAssert(message);
    OWSAssert(recipient);
    OWSAssert(thread || [message isKindOfClass:[OWSOutgoingSyncMessage class]]);
    
    DDLogInfo(@"%@ attempting to send message: %@, timestamp: %llu, recipient: %@",
              self.logTag,
              message.class,
              message.timestamp,
              recipient.uniqueId);
    AssertIsOnSendingQueue();
    
    if ([TSPreKeyManager isAppLockedDueToPreKeyUpdateFailures]) {
        // Retry prekey update every time user tries to send a message while app
        // is disabled due to prekey update failures.
        //
        // Only try to update the signed prekey; updating it is sufficient to
        // re-enable message sending.
        [TSPreKeyManager registerPreKeysWithMode:RefreshPreKeysMode_SignedOnly
                                         success:^{
                                             DDLogInfo(@"%@ New prekeys registered with server.", self.logTag);
                                         }
                                         failure:^(NSError *error) {
                                             DDLogWarn(@"%@ Failed to update prekeys with the server: %@", self.logTag, error);
                                         }];
        
        NSError *error = OWSErrorMakeMessageSendDisabledDueToPreKeyUpdateFailuresError();
        [error setIsRetryable:YES];
        return failureHandler(error);
    }
    
    if (remainingAttemptsParam <= 0) {
        // We should always fail with a specific error.
        NSError *error = OWSErrorMakeFailedToSendOutgoingMessageError();
        [error setIsRetryable:YES];
        return failureHandler(error);
    }
    int remainingAttempts = remainingAttemptsParam - 1;
    
    NSArray<NSDictionary *> *deviceMessages;
    @try {
        deviceMessages = [self deviceMessages:message recipient:recipient onlyDeviceId:nil];
    } @catch (NSException *exception) {
        deviceMessages = @[];
        if ([exception.name isEqualToString:UntrustedIdentityKeyException]) {
            // This *can* happen under normal usage, but it should happen relatively rarely.
            // We expect it to happen whenever Bob reinstalls, and Alice messages Bob before
            // she can pull down his latest identity.
            // If it's happening a lot, we should rethink our profile fetching strategy.
            NSString *localizedErrorDescriptionFormat
            = NSLocalizedString(@"FAILED_SENDING_BECAUSE_UNTRUSTED_IDENTITY_KEY",
                                @"action sheet header when re-sending message which failed because of untrusted identity keys");
            
            NSString *localizedErrorDescription =
            [NSString stringWithFormat:localizedErrorDescriptionFormat,
             [self.contactsManager displayNameForRecipientId:recipient.uniqueId]];
            NSError *error = OWSErrorMakeUntrustedIdentityError(localizedErrorDescription, recipient.uniqueId);
            
            // Key will continue to be unaccepted, so no need to retry. It'll only cause us to hit the Pre-Key request
            // rate limit
            [error setIsRetryable:NO];
            // Avoid the "Too many failures with this contact" error rate limiting.
            [error setIsFatal:YES];
            
            PreKeyBundle *_Nullable newKeyBundle = exception.userInfo[TSInvalidPreKeyBundleKey];
            if (newKeyBundle == nil) {
                DDLogError(@"messageSenderErrorMissingNewPreKeyBundle");
                failureHandler(error);
                return;
            }
            
            if (![newKeyBundle isKindOfClass:[PreKeyBundle class]]) {
                DDLogError(@"messageSenderErrorUnexpectedKeyBundle");
                failureHandler(error);
                return;
            }
            
            NSData *newIdentityKeyWithVersion = newKeyBundle.identityKey;
            
            if (![newIdentityKeyWithVersion isKindOfClass:[NSData class]]) {
                DDLogError(@"messageSenderErrorInvalidIdentityKeyType");
                failureHandler(error);
                return;
            }
            
            // TODO migrate to storing the full 33 byte representation of the identity key.
            if (newIdentityKeyWithVersion.length != kIdentityKeyLength) {
                DDLogError(@"messageSenderErrorInvalidIdentityKeyLength");
                failureHandler(error);
                return;
            }
            
            NSData *newIdentityKey;// = [newIdentityKeyWithVersion removeKeyType];
            @try {
                newIdentityKey = [newIdentityKeyWithVersion throws_removeKeyType];
            } @catch (NSException *exception) {
                OWSFailDebug(@"exception: %@", exception);
            }

            [[OWSIdentityManager sharedManager] saveRemoteIdentity:newIdentityKey recipientId:recipient.uniqueId];
            
            failureHandler(error);
            return;
        }
        
        if ([exception.name isEqualToString:MessageSenderRateLimitedException]) {
            NSError *error = OWSErrorWithCodeDescription(OWSErrorCodeSignalServiceRateLimited,
                                                         NSLocalizedString(@"FAILED_SENDING_BECAUSE_RATE_LIMIT",
                                                                           @"action sheet header when re-sending message which failed because of too many attempts"));
            
            // We're already rate-limited. No need to exacerbate the problem.
            [error setIsRetryable:NO];
            // Avoid exacerbating the rate limiting.
            [error setIsFatal:YES];
            return failureHandler(error);
        }
        
        if (remainingAttempts == 0) {
            DDLogWarn(@"%@ Terminal failure to build any device messages. Giving up with exception:%@",
                      self.logTag,
                      exception);
            NSError *error = OWSErrorMakeFailedToSendOutgoingMessageError();
            // Since we've already repeatedly failed to build messages, it's unlikely that repeating the whole process
            // will succeed.
            [error setIsRetryable:NO];
            return failureHandler(error);
        }
    }
    
    NSString *localNumber = [TSAccountManager localUID];
    BOOL isLocalNumber = [localNumber isEqualToString:recipient.uniqueId];
    if (isLocalNumber) {
        OWSAssert([message isKindOfClass:[OWSOutgoingSyncMessage class]]);
        // Messages sent to the "local number" should be sync messages.
        //
        // We can skip sending sync messages if we know that we have no linked
        // devices. However, we need to be sure to handle the case where the
        // linked device list has just changed.
        //
        // The linked device list is reflected in two separate pieces of state:
        //
        // * OWSDevice's state is updated when you link or unlink a device.
        // * RelayRecipient's state is updated by 409 "Mismatched devices"
        //   responses from the service.
        //
        // If _both_ of these pieces of state agree that there are no linked
        // devices, then can safely skip sending sync message.
        
        // 1. Check OWSDevice's state.
        BOOL mayHaveLinkedDevices = [OWSDeviceManager.sharedManager mayHaveLinkedDevices:self.dbConnection];
        
        // 2. Check RelayRecipient's state.
        BOOL hasDeviceMessages = deviceMessages.count > 0;
        
        DDLogInfo(@"%@ mayHaveLinkedDevices: %d, hasDeviceMessages: %d",
                  self.logTag,
                  mayHaveLinkedDevices,
                  hasDeviceMessages);
        
        if (!mayHaveLinkedDevices && !hasDeviceMessages) {
            DDLogInfo(@"%@ Ignoring sync message without secondary devices: %@", self.logTag, [message class]);
            OWSAssert([message isKindOfClass:[OWSOutgoingSyncMessage class]]);
            
            dispatch_async([OWSDispatch sendingQueue], ^{
                // This emulates the completion logic of an actual successful save (see below).
                [self.dbConnection readWriteWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
                    [message updateWithSkippedRecipient:localNumber transaction:transaction];
                }];
                successHandler();
            });
            
            return;
        } else if (mayHaveLinkedDevices && !hasDeviceMessages) {
            // We may have just linked a new secondary device which is not yet reflected in
            // the RelayRecipient that corresponds to ourself.  Proceed.  Client should learn
            // of new secondary devices via 409 "Mismatched devices" response.
            DDLogWarn(@"%@ account has secondary devices, but sync message has no device messages", self.logTag);
        } else if (!mayHaveLinkedDevices && hasDeviceMessages) {
            OWSFail(@"%@ sync message has device messages for unknown secondary devices.", self.logTag);
        }
        // TODO: Investigate other places where device query may be taking place.
        //    } else {
        //        OWSAssert(deviceMessages.count > 0);
    }
    
    if (deviceMessages.count == 0) {
        // This might happen:
        //
        // * The first (after upgrading?) time we send a sync message to our linked devices.
        // * After unlinking all linked devices.
        // * After trying and failing to link a device.
        // * The first time we send a message to a user, if they don't have their
        //   default device.  For example, if they have unregistered
        //   their primary but still have a linked device. Or later, when they re-register.
        //
        // When we're not sure if we have linked devices, we need to try
        // to send self-sync messages even if they have no device messages
        // so that we can learn from the service whether or not there are
        // linked devices that we don't know about.
        DDLogWarn(@"%@ Sending a message with no device messages.", self.logTag);
    }
    
    TSRequest *request = [OWSRequestFactory submitMessageRequestWithRecipient:recipient.uniqueId
                                                                     messages:deviceMessages
                                                                    timeStamp:message.timestamp];
    if (useWebsocketIfAvailable && TSSocketManager.canMakeRequests) {
        [TSSocketManager.sharedManager makeRequest:request
                                           success:^(id _Nullable responseObject) {
                                               [self messageSendDidSucceed:message
                                                                 recipient:recipient
                                                             isLocalNumber:isLocalNumber
                                                            deviceMessages:deviceMessages
                                                                   success:successHandler];
                                           }
                                           failure:^(NSInteger statusCode, NSData *_Nullable responseData, NSError *error) {
                                               dispatch_async([OWSDispatch sendingQueue], ^{
                                                   DDLogDebug(
                                                              @"%@ in %s falling back to REST since first attempt failed.", self.logTag, __PRETTY_FUNCTION__);
                                                   
                                                   // Websockets can fail in different ways, so we don't decrement remainingAttempts for websocket
                                                   // failure. Instead we fall back to REST, which will decrement retries. e.g. after linking a new
                                                   // device, sync messages will fail until the websocket re-opens.
                                                   [self sendMessageToService:message
                                                                    recipient:recipient
                                                                       thread:thread
                                                                     attempts:remainingAttemptsParam
                                                      useWebsocketIfAvailable:NO
                                                                      success:successHandler
                                                                      failure:failureHandler];
                                               });
                                           }];
    } else {
        [self.networkManager makeRequest:request
                                 success:^(NSURLSessionDataTask *task, id responseObject) {
                                     [self messageSendDidSucceed:message
                                                       recipient:recipient
                                                   isLocalNumber:isLocalNumber
                                                  deviceMessages:deviceMessages
                                                         success:successHandler];
                                 }
                                 failure:^(NSURLSessionDataTask *task, NSError *error) {
                                     NSHTTPURLResponse *response = (NSHTTPURLResponse *)task.response;
                                     NSInteger statusCode = response.statusCode;
                                     NSData *_Nullable responseData = error.userInfo[AFNetworkingOperationFailingURLResponseDataErrorKey];
                                     
                                     [self messageSendDidFail:message
                                                    recipient:recipient
                                                       thread:thread
                                                isLocalNumber:isLocalNumber
                                               deviceMessages:deviceMessages
                                            remainingAttempts:remainingAttempts
                                                   statusCode:statusCode
                                                        error:error
                                                 responseData:responseData
                                                      success:successHandler
                                                      failure:failureHandler];
                                 }];
    }
}

- (void)messageSendDidSucceed:(TSOutgoingMessage *)message
                    recipient:(RelayRecipient *)recipient
                isLocalNumber:(BOOL)isLocalNumber
               deviceMessages:(NSArray<NSDictionary *> *)deviceMessages
                      success:(void (^)(void))successHandler
{
    OWSAssert(message);
    OWSAssert(recipient);
    OWSAssert(deviceMessages);
    OWSAssert(successHandler);
    
    DDLogInfo(@"%@ Message send succeeded.", self.logTag);
    
    if (isLocalNumber && deviceMessages.count == 0) {
        DDLogInfo(@"%@ Sent a message with no device messages; clearing 'mayHaveLinkedDevices'.", self.logTag);
        // In order to avoid skipping necessary sync messages, the default value
        // for mayHaveLinkedDevices is YES.  Once we've successfully sent a
        // sync message with no device messages (e.g. the service has confirmed
        // that we have no linked devices), we can set mayHaveLinkedDevices to NO
        // to avoid unnecessary message sends for sync messages until we learn
        // of a linked device (e.g. through the device linking UI or by receiving
        // a sync message, etc.).
        [OWSDeviceManager.sharedManager clearMayHaveLinkedDevicesIfNotSet];
    }
    
    dispatch_async([OWSDispatch sendingQueue], ^{
        [self.dbConnection readWriteWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
            [message updateWithSentRecipient:recipient.uniqueId transaction:transaction];
            
            // If we've just delivered a message to a user, we know they
            // have a valid Signal account.
            //            [RelayRecipient markRecipientAsRegisteredAndGet:recipient.uniqueId transaction:transaction];
        }];
        
        [self handleMessageSentLocally:message];
        successHandler();
    });
}

- (void)messageSendDidFail:(TSOutgoingMessage *)message
                 recipient:(RelayRecipient *)recipient
                    thread:(nullable TSThread *)thread
             isLocalNumber:(BOOL)isLocalNumber
            deviceMessages:(NSArray<NSDictionary *> *)deviceMessages
         remainingAttempts:(int)remainingAttempts
                statusCode:(NSInteger)statusCode
                     error:(NSError *)responseError
              responseData:(nullable NSData *)responseData
                   success:(void (^)(void))successHandler
                   failure:(RetryableFailureHandler)failureHandler
{
    OWSAssert(message);
    OWSAssert(recipient);
    OWSAssert(thread || [message isKindOfClass:[OWSOutgoingSyncMessage class]]);
    OWSAssert(deviceMessages);
    OWSAssert(responseError);
    OWSAssert(successHandler);
    OWSAssert(failureHandler);
    
    DDLogInfo(@"%@ sending to recipient: %@, failed with error.", self.logTag, recipient.uniqueId);
    
    void (^retrySend)(void) = ^void() {
        if (remainingAttempts <= 0) {
            // Since we've already repeatedly failed to send to the messaging API,
            // it's unlikely that repeating the whole process will succeed.
            [responseError setIsRetryable:NO];
            return failureHandler(responseError);
        }
        
        dispatch_async([OWSDispatch sendingQueue], ^{
            DDLogDebug(@"%@ Retrying: %@", self.logTag, message.debugDescription);
            [self sendMessageToService:message
                             recipient:recipient
                                thread:thread
                              attempts:remainingAttempts
               useWebsocketIfAvailable:NO
                               success:successHandler
                               failure:failureHandler];
        });
    };
    
    void (^handle404)(void) = ^{
        DDLogWarn(@"%@ Unregistered recipient: %@", self.logTag, recipient.uniqueId);
        
        OWSAssert(thread);
        
        dispatch_async([OWSDispatch sendingQueue], ^{
            [self unregisteredRecipient:recipient message:message thread:thread];
            
            NSError *error = OWSErrorMakeNoSuchSignalRecipientError();
            // No need to retry if the recipient is not registered.
            [error setIsRetryable:NO];
            // If one member of a group deletes their account,
            // the group should ignore errors when trying to send
            // messages to this ex-member.
            [error setShouldBeIgnoredForGroups:YES];
            failureHandler(error);
        });
    };
    
    switch (statusCode) {
        case 401: {
            DDLogWarn(@"%@ Unable to send due to invalid credentials. Did the user's client get de-authed by "
                      @"registering elsewhere?",
                      self.logTag);
            NSError *error = OWSErrorWithCodeDescription(OWSErrorCodeSignalServiceFailure,
                                                         NSLocalizedString(
                                                                           @"ERROR_DESCRIPTION_SENDING_UNAUTHORIZED", @"Error message when attempting to send message"));
            // No need to retry if we've been de-authed.
            [error setIsRetryable:NO];
            return failureHandler(error);
        }
        case 404: {
            handle404();
            return;
        }
        case 409: {
            // Mismatched devices
            DDLogWarn(@"%@ Mismatched devices for recipient: %@ (%zd)",
                      self.logTag,
                      recipient.uniqueId,
                      deviceMessages.count);
            
            NSError *_Nullable error = nil;
            NSDictionary *_Nullable responseJson = nil;
            if (responseData) {
                responseJson = [NSJSONSerialization JSONObjectWithData:responseData options:0 error:&error];
            }
            if (error || !responseJson) {
                [error setIsRetryable:YES];
                return failureHandler(error);
            }
            
            NSNumber *_Nullable errorCode = responseJson[@"code"];
            if ([@(404) isEqual:errorCode]) {
                // Some 404s are returned as 409.
                handle404();
                return;
            }
            
            [self handleMismatchedDevicesWithResponseJson:responseJson recipient:recipient completion:retrySend];
            break;
        }
        case 410: {
            // Stale devices
            DDLogWarn(@"%@ Stale devices for recipient: %@", self.logTag, recipient.uniqueId);
            
            NSError *_Nullable error = nil;
            NSDictionary *_Nullable responseJson = nil;
            if (responseData) {
                responseJson = [NSJSONSerialization JSONObjectWithData:responseData options:0 error:&error];
            }
            if (error || !responseJson) {
                DDLogWarn(@"Stale devices but server didn't specify devices in response.");
                NSError *error = OWSErrorMakeUnableToProcessServerResponseError();
                [error setIsRetryable:YES];
                return failureHandler(error);
            }
            
            [self handleStaleDevicesWithResponseJson:responseJson recipientId:recipient.uniqueId completion:retrySend];
            break;
        }
        default:
            retrySend();
            break;
    }
}

- (void)handleMismatchedDevicesWithResponseJson:(NSDictionary *)responseJson
                                      recipient:(RelayRecipient *)recipient
                                     completion:(void (^)(void))completionHandler
{
    OWSAssert(responseJson);
    OWSAssert(recipient);
    OWSAssert(completionHandler);
    
    NSArray *extraDevices = responseJson[@"extraDevices"];
    NSArray *missingDevices = responseJson[@"missingDevices"];
    
    if (missingDevices.count > 0) {
        NSString *localNumber = [TSAccountManager localUID];
        if ([localNumber isEqualToString:recipient.uniqueId]) {
            [OWSDeviceManager.sharedManager setMayHaveLinkedDevices];
        }
    }
    
    [self.dbConnection
     readWriteWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
         if (extraDevices.count < 1 && missingDevices.count < 1) {
             DDLogError(@"messageSenderErrorNoMissingOrExtraDevices");
         }
         
         if (extraDevices && extraDevices.count > 0) {
             DDLogInfo(@"%@ removing extra devices: %@", self.logTag, extraDevices);
             for (NSNumber *extraDeviceId in extraDevices) {
                 [self.primaryStorage deleteSessionForContact:recipient.uniqueId
                                                     deviceId:extraDeviceId.intValue
                                              protocolContext:transaction];
             }
             
             [recipient removeDevicesFromRecipient:[NSOrderedSet orderedSetWithArray:extraDevices] transaction:transaction];
         }
         
         if (missingDevices && missingDevices.count > 0) {
             DDLogInfo(@"%@ Adding missing devices: %@", self.logTag, missingDevices);
             [recipient addDevicesToRegisteredRecipient:[NSOrderedSet orderedSetWithArray:missingDevices]
                                            transaction:transaction];
         }
         
         dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
             completionHandler();
         });
     }];
}

- (void)handleMessageSentLocally:(TSOutgoingMessage *)message
{
    if (message.shouldSyncTranscript) {
        // TODO: I suspect we shouldn't optimistically set hasSyncedTranscript.
        //       We could set this in a success handler for [sendSyncTranscriptForMessage:].
        [self.dbConnection readWriteWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
            [message updateWithHasSyncedTranscript:YES transaction:transaction];
        }];
        [self sendSyncTranscriptForMessage:message];
    }
    
    [self.dbConnection readWriteWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
        [[OWSDisappearingMessagesJob sharedJob] startAnyExpirationForMessage:message
                                                         expirationStartedAt:[NSDate ows_millisecondTimeStamp]
                                                                 transaction:transaction];
    }];
}

- (void)sendSyncTranscriptForMessage:(TSOutgoingMessage *)message
{
    OWSOutgoingSentMessageTranscript *sentMessageTranscript =
    [[OWSOutgoingSentMessageTranscript alloc] initWithOutgoingMessage:message];
    
    [self sendMessageToService:sentMessageTranscript
                     recipient:TSAccountManager.selfRecipient
                        thread:message.thread
                      attempts:MessageSenderRetryAttempts
       useWebsocketIfAvailable:YES
                       success:^{
                           DDLogInfo(@"Successfully sent sync transcript.");
                       }
                       failure:^(NSError *error) {
                           // FIXME: We don't yet honor the isRetryable flag here, since sendSyncTranscriptForMessage
                           // isn't yet wrapped in our retryable SendMessageOperation. Addressing this would require
                           // a refactor to the MessageSender. Note that we *do* however continue to respect the
                           // MessageSenderRetryAttempts, which is an "inner" retry loop, encompassing only the
                           // messaging API.
                           DDLogInfo(@"Failed to send sync transcript: %@ (isRetryable: %d)", error, [error isRetryable]);
                       }];
}

- (NSArray<NSDictionary *> *)deviceMessages:(TSOutgoingMessage *)message recipient:(RelayRecipient *)recipient onlyDeviceId:(nullable NSNumber *)onlyDeviceId
{
    OWSAssert(message);
    OWSAssert(recipient);
    
    NSMutableArray *messagesArray = [NSMutableArray arrayWithCapacity:(onlyDeviceId != nil ? 1 : recipient.devices.count)];
    
    NSData *plainText = [message buildPlainTextData:recipient];
    DDLogDebug(@"%@ built message: %@ plainTextData.length: %lu",
               self.logTag,
               [message class],
               (unsigned long)plainText.length);
    
    for (NSNumber *deviceNumber in recipient.devices) {
        if (onlyDeviceId != nil && deviceNumber.longValue != onlyDeviceId.longValue) { continue; }
        @try {
            __block NSDictionary *messageDict;
            __block NSException *encryptionException;
            [self.dbConnection
             readWriteWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
                 @try {
                     messageDict = [self encryptedMessageWithPlaintext:plainText
                                                             recipient:recipient
                                                              deviceId:deviceNumber
                                                         keyingStorage:self.primaryStorage
                                                              isSilent:message.isSilent
                                                           transaction:transaction];
                 } @catch (NSException *exception) {
                     encryptionException = exception;
                 }
             }];
            
            if (encryptionException) {
                DDLogInfo(@"%@ Exception during encryption: %@", self.logTag, encryptionException);
                @throw encryptionException;
            }
            
            if (messageDict) {
                [messagesArray addObject:messageDict];
            } else {
                OWSRaiseException(InvalidMessageException, @"Failed to encrypt message");
            }
        } @catch (NSException *exception) {
            if ([exception.name isEqualToString:MessageSenderInvalidDeviceException]) {
                [self.dbConnection readWriteWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
                    [recipient removeDevicesFromRecipient:[NSOrderedSet orderedSetWithObject:deviceNumber] transaction:transaction];
                }];
            } else {
                @throw exception;
            }
        }
    }
    
    return [messagesArray copy];
}

- (NSDictionary *)encryptedMessageWithPlaintext:(NSData *)plainText
                                      recipient:(RelayRecipient *)recipient
                                       deviceId:(NSNumber *)deviceNumber
                                  keyingStorage:(OWSPrimaryStorage *)storage
                                       isSilent:(BOOL)isSilent
                                    transaction:(YapDatabaseReadWriteTransaction *)transaction
{
    OWSAssert(plainText);
    OWSAssert(recipient);
    OWSAssert(deviceNumber);
    OWSAssert(storage);
    OWSAssert(transaction);
    
    NSString *identifier = recipient.uniqueId;
    OWSAssert(identifier.length > 0);
    
    if (![storage containsSession:identifier deviceId:[deviceNumber intValue] protocolContext:transaction]) {
        __block dispatch_semaphore_t sema = dispatch_semaphore_create(0);
        __block PreKeyBundle *_Nullable bundle;
        __block NSException *_Nullable exception;
        // It's not ideal that we're using a semaphore inside a read/write transaction.
        // To avoid deadlock, we need to ensure that our success/failure completions
        // are called _off_ the main thread.  Otherwise we'll deadlock if the main
        // thread is blocked on opening a transaction.
        TSRequest *request =
        [OWSRequestFactory recipientPrekeyRequestWithRecipient:identifier deviceId:[deviceNumber stringValue]];
        [self.networkManager makeRequest:request
                         completionQueue:dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0)
                                 success:^(NSURLSessionDataTask *task, id responseObject) {
                                     bundle = [PreKeyBundle preKeyBundleFromDictionary:responseObject forDeviceNumber:deviceNumber];
                                     dispatch_semaphore_signal(sema);
                                 }
                                 failure:^(NSURLSessionDataTask *task, NSError *error) {
                                     DDLogError(@"Server replied to PreKeyBundle request with error: %@", error);
                                     NSHTTPURLResponse *response = (NSHTTPURLResponse *)task.response;
                                     if (response.statusCode == 404) {
                                         // Can't throw exception from within callback as it's probabably a different thread.
                                         exception = [NSException exceptionWithName:MessageSenderInvalidDeviceException
                                                                             reason:@"Device not registered"
                                                                           userInfo:nil];
                                     } else if (response.statusCode == 413) {
                                         // Can't throw exception from within callback as it's probabably a different thread.
                                         exception = [NSException exceptionWithName:MessageSenderRateLimitedException
                                                                             reason:@"Too many prekey requests"
                                                                           userInfo:nil];
                                     }
                                     dispatch_semaphore_signal(sema);
                                 }];
        // FIXME: Currently this happens within a readwrite transaction - meaning our read-write transaction blocks
        // on a network request.
        dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);
        if (exception) {
            @throw exception;
        }
        
        if (!bundle) {
            OWSRaiseException(
                              InvalidVersionException, @"Can't get a prekey bundle from the server with required information");
        } else {
            SessionBuilder *builder = [[SessionBuilder alloc] initWithSessionStore:storage
                                                                       preKeyStore:storage
                                                                 signedPreKeyStore:storage
                                                                  identityKeyStore:[OWSIdentityManager sharedManager]
                                                                       recipientId:identifier
                                                                          deviceId:[deviceNumber intValue]];
            @try {
                [builder throws_processPrekeyBundle:bundle protocolContext:transaction];
            } @catch (NSException *exception) {
                if ([exception.name isEqualToString:UntrustedIdentityKeyException]) {
                    OWSRaiseExceptionWithUserInfo(UntrustedIdentityKeyException,
                                                  (@{ TSInvalidPreKeyBundleKey : bundle, TSInvalidRecipientKey : identifier }),
                                                  @"");
                }
                @throw exception;
            }
        }
    }
    
    SessionCipher *cipher = [[SessionCipher alloc] initWithSessionStore:storage
                                                            preKeyStore:storage
                                                      signedPreKeyStore:storage
                                                       identityKeyStore:[OWSIdentityManager sharedManager]
                                                            recipientId:identifier
                                                               deviceId:[deviceNumber intValue]];
    
    id<CipherMessage> encryptedMessage;
    OWSMessageServiceParams *messageParams;
    @try {
        encryptedMessage = [cipher throws_encryptMessage:[plainText paddedMessageBody] protocolContext:transaction];
        
        NSData *serializedMessage = encryptedMessage.serialized;
        TSWhisperMessageType messageType = [self messageTypeForCipherMessage:encryptedMessage];
        
        messageParams = [[OWSMessageServiceParams alloc] initWithType:messageType
                                                          recipientId:identifier
                                                               device:[deviceNumber intValue]
                                                              content:serializedMessage
                                                             isSilent:isSilent
                                                       registrationId:[cipher throws_remoteRegistrationId:transaction]];
    } @catch (NSException *exception) {
        OWSFailDebug(@"exception: %@", exception);
    }

    NSError *error;
    NSDictionary *jsonDict = [MTLJSONAdapter JSONDictionaryFromModel:messageParams error:&error];
    
    if (error) {
        DDLogError(@"messageSendErrorCouldNotSerializeMessageJson");
        return nil;
    }
    
    return jsonDict;
}

- (TSWhisperMessageType)messageTypeForCipherMessage:(id<CipherMessage>)cipherMessage
{
    if ([cipherMessage isKindOfClass:[PreKeyWhisperMessage class]]) {
        return TSPreKeyWhisperMessageType;
    } else if ([cipherMessage isKindOfClass:[WhisperMessage class]]) {
        return TSEncryptedWhisperMessageType;
    }
    return TSUnknownMessageType;
}

- (void)saveGroupMessage:(TSOutgoingMessage *)message inThread:(TSThread *)thread
{
    // TODO: Modify this to respond to Control Messages
    //    if (message.groupMetaMessage == TSGroupMessageDeliver) {
    //        // TODO: Why is this necessary?
    //        [message save];
    //    } else if (message.groupMetaMessage == TSGroupMessageQuit) {
    //        [[[TSInfoMessage alloc] initWithTimestamp:message.timestamp
    //                                         inThread:thread
    //                                      messageType:TSInfoMessageTypeConversationQuit
    //                                    customMessage:message.customMessage] save];
    //    } else {
    //        [[[TSInfoMessage alloc] initWithTimestamp:message.timestamp
    //                                         inThread:thread
    //                                      messageType:TSInfoMessageTypeConversationUpdate
    //                                    customMessage:message.customMessage] save];
    //    }
}

// Called when the server indicates that the devices no longer exist - e.g. when the remote recipient has reinstalled.
- (void)handleStaleDevicesWithResponseJson:(NSDictionary *)responseJson
                               recipientId:(NSString *)identifier
                                completion:(void (^)(void))completionHandler
{
    dispatch_async([OWSDispatch sendingQueue], ^{
        NSArray *devices = responseJson[@"staleDevices"];
        
        if (!([devices count] > 0)) {
            return;
        }
        
        [self.dbConnection asyncReadWriteWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
            for (NSUInteger i = 0; i < [devices count]; i++) {
                int deviceNumber = [devices[i] intValue];
                [[OWSPrimaryStorage sharedManager] deleteSessionForContact:identifier
                                                                  deviceId:deviceNumber
                                                           protocolContext:transaction];
            }
        }];
        completionHandler();
    });
}

-(void)sendSpecialMessage:(TSOutgoingMessage *)message
              recipientId:(NSString *)recipientId
                 attempts:(int)remainingAttempts
                  success:(void (^)(void))successHandler
                  failure:(void (^)(NSError *error))failureHandler
{
    [self sendSpecialMessage:message
                 recipientId:recipientId
                onlyDeviceId:nil
                    attempts:remainingAttempts
                     success:successHandler
                     failure:failureHandler];
}

-(void)sendSpecialMessage:(TSOutgoingMessage *)message
              recipientId:(NSString *)recipientId
             onlyDeviceId:(nullable NSNumber *)onlyDeviceId
                 attempts:(int)remainingAttempts
                  success:(void (^)(void))successHandler
                  failure:(void (^)(NSError *error))failureHandler
{
    if (remainingAttempts <= 0) {
        // We should always fail with a specific error.
        DDLogError(@"%@ Unexpected generic failure.", self.logTag);
        return failureHandler(OWSErrorMakeFailedToSendOutgoingMessageError());
    }
    remainingAttempts -= 1;
    
    __block RelayRecipient *recipient =  nil;
    [self.dbConnection readWithBlock:^(YapDatabaseReadTransaction * _Nonnull transaction) {
        recipient = [RelayRecipient getOrBuildUnsavedRecipientForRecipientId:recipientId transaction:transaction];
    }];
    
    @try {
        NSArray *messagesArray = [self deviceMessages:message recipient:recipient onlyDeviceId:onlyDeviceId];
        
        if (onlyDeviceId != nil && messagesArray.count == 0) {
            DDLogDebug(@"%@ Current addresses don't have the specified device# %@.", self.logTag, onlyDeviceId);
        }

        TSRequest *request = nil;
        if (onlyDeviceId != nil && messagesArray.count == 1) {
            NSMutableDictionary *msg = [messagesArray[0] mutableCopy];
            [msg setObject:@(message.timestamp) forKey:@"timestamp"];
            request = [OWSRequestFactory submitMessageRequestWithRecipient:recipient.uniqueId
                                                         recipientDeviceId:onlyDeviceId
                                                                   message:msg];
        } else {
            request = [OWSRequestFactory submitMessageRequestWithRecipient:recipient.uniqueId
                                                                  messages:messagesArray
                                                                 timeStamp:message.timestamp];
        }
        [self.networkManager makeRequest:request
                                 success:^(NSURLSessionDataTask *task, id responseObject) {
                                     DDLogDebug(@"Special send successful.");
                                     successHandler();
                                 }
                                 failure:^(NSURLSessionDataTask *task, NSError *error) {
                                     NSHTTPURLResponse *response = (NSHTTPURLResponse *)task.response;
                                     long statuscode = response.statusCode;
                                     NSData *responseData = error.userInfo[AFNetworkingOperationFailingURLResponseDataErrorKey];
                                     
                                     NSError *err = nil;
                                     NSDictionary *serializedResponse = [NSJSONSerialization JSONObjectWithData:responseData options:0 error:&err];

                                     void (^retrySend)(void) = ^void() {
                                         if (remainingAttempts <= 0) {
                                             return failureHandler(error);
                                         }
                                         
                                         dispatch_async([OWSDispatch sendingQueue], ^{
                                             [self sendSpecialMessage:message
                                                          recipientId:recipient.uniqueId
                                                         onlyDeviceId:onlyDeviceId
                                                             attempts:remainingAttempts
                                                              success:successHandler
                                                              failure:failureHandler];
                                         });
                                     };
                                     
                                     switch (statuscode) {
                                         case 404: {
                                             [recipient remove];
                                             return failureHandler(OWSErrorMakeNoSuchSignalRecipientError());
                                         }
                                         case 409: {
                                             // Mismatched devices
                                             DDLogWarn(@"%@ Mismatch Devices.", self.logTag);
                                             
                                             if (!responseData || err) {
                                                 DDLogError(@"%@ Failed to serialize response of mismatched devices: %@", self.logTag, err);
                                                 return failureHandler(err);
                                             }
                                             
                                             [self handleMismatchedDevicesWithResponseJson:serializedResponse recipient:recipient completion:retrySend];

                                             break;
                                         }
                                         case 410: {
                                             // staledevices
                                             DDLogWarn(@"Stale devices");
                                             
                                             if (!responseData || err) {
                                                 DDLogWarn(@"Stale devices but server didn't specify devices in response.");
                                                 return failureHandler(OWSErrorMakeUnableToProcessServerResponseError());
                                             }
                                             
                                             [self handleStaleDevicesWithResponseJson:serializedResponse recipientId:recipient.uniqueId completion:retrySend];

                                             break;
                                         }
                                         default:
                                             retrySend();
                                             break;
                                     }
                                 }];
        
    }
    @catch (NSException *exception) {
        DDLogDebug(@"Exception thrown by special sender: %@", exception.name);
    }
}


@end

NS_ASSUME_NONNULL_END
