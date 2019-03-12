//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import "OWSMessageDecrypter.h"
#import "NSData+messagePadding.h"
#import "NotificationsProtocol.h"
#import "OWSBlockingManager.h"
#import "OWSError.h"
#import "OWSIdentityManager.h"
#import "OWSPrimaryStorage+PreKeyStore.h"
#import "OWSPrimaryStorage+SessionStore.h"
#import "OWSPrimaryStorage+SignedPreKeyStore.h"
#import "OWSPrimaryStorage.h"
#import "OWSSignalServiceProtos.pb.h"
#import "TSAccountManager.h"
#import "TSThread.h"
#import "TSErrorMessage.h"
#import "TSPreKeyManager.h"
#import "TextSecureKitEnv.h"
#import "SSKAsserts.h"
#import "OWSEndSessionMessage.h"
#import "MessageSender.h"
#import "TSInfoMessage.h"
#import <RelayServiceKit/RelayServiceKit-Swift.h>

@import AxolotlKit;
@import SignalCoreKit;

NS_ASSUME_NONNULL_BEGIN

@interface OWSMessageDecrypter ()

@property (nonatomic, readonly) OWSPrimaryStorage *primaryStorage;
@property (nonatomic, readonly) YapDatabaseConnection *dbConnection;
@property (nonatomic, readonly) OWSBlockingManager *blockingManager;
@property (nonatomic, readonly) OWSIdentityManager *identityManager;

@end

#pragma mark -

@implementation OWSMessageDecrypter

+ (instancetype)sharedManager
{
    static OWSMessageDecrypter *sharedMyManager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedMyManager = [[self alloc] initDefault];
    });
    return sharedMyManager;
}

- (instancetype)initDefault
{
    OWSPrimaryStorage *primaryStorage = [OWSPrimaryStorage sharedManager];
    OWSIdentityManager *identityManager = [OWSIdentityManager sharedManager];
    OWSBlockingManager *blockingManager = [OWSBlockingManager sharedManager];

    return [self initWithPrimaryStorage:primaryStorage identityManager:identityManager blockingManager:blockingManager];
}

- (instancetype)initWithPrimaryStorage:(OWSPrimaryStorage *)primaryStorage
                       identityManager:(OWSIdentityManager *)identityManager
                       blockingManager:(OWSBlockingManager *)blockingManager
{
    self = [super init];

    if (!self) {
        return self;
    }

    _primaryStorage = primaryStorage;
    _identityManager = identityManager;
    _blockingManager = blockingManager;

    _dbConnection = primaryStorage.newDatabaseConnection;

    OWSSingletonAssert();

    return self;
}

#pragma mark - Blocking

- (BOOL)isEnvelopeBlocked:(SSKEnvelope *)envelope
{
    OWSAssert(envelope);

    return [_blockingManager.blockedPhoneNumbers containsObject:envelope.source];
}

#pragma mark - Decryption

- (void)decryptEnvelope:(SSKEnvelope *)envelope
           successBlock:(DecryptSuccessBlock)successBlockParameter
           failureBlock:(DecryptFailureBlock)failureBlockParameter
{
    OWSAssert(envelope);
    OWSAssert(successBlockParameter);
    OWSAssert(failureBlockParameter);
    OWSAssert([TSAccountManager isRegistered]);

    // successBlock is called synchronously so that we can avail ourselves of
    // the transaction.
    //
    // Ensure that failureBlock is called on a worker queue.
    DecryptFailureBlock failureBlock = ^() {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            failureBlockParameter();
        });
    };

    DecryptSuccessBlock successBlock
        = ^(NSData *_Nullable plaintextData, YapDatabaseReadWriteTransaction *transaction) {
            [RelayRecipient markAsRegistered:envelope.source deviceId:envelope.sourceDevice transaction:transaction];
              successBlockParameter(plaintextData, transaction);
          };

    @try {
        DDLogInfo(@"%@ decrypting envelope: %@", self.logTag, [self descriptionForEnvelope:envelope]);

        OWSAssert(envelope.source.length > 0);
        if ([self isEnvelopeBlocked:envelope]) {
            DDLogInfo(@"%@ ignoring blocked envelope: %@", self.logTag, envelope.source);
            failureBlock();
            return;
        }

        switch (envelope.type) {
            case SSKEnvelopeTypeCiphertext: {
                [self decryptSecureMessage:envelope
                    successBlock:^(NSData *_Nullable plaintextData, YapDatabaseReadWriteTransaction *transaction) {
                        DDLogDebug(@"%@ decrypted secure message.", self.logTag);
                        successBlock(plaintextData, transaction);
                    }
                    failureBlock:^(NSError *_Nullable error) {
                        DDLogError(@"%@ decrypting secure message from address: %@ failed with error: %@",
                            self.logTag,
                            envelopeAddress(envelope),
                            error);
                        failureBlock();
                    }];
                // Return to avoid double-acknowledging.
                return;
            }
            case SSKEnvelopeTypePrekeyBundle: {
                [self decryptPreKeyBundle:envelope
                    successBlock:^(NSData *_Nullable plaintextData, YapDatabaseReadWriteTransaction *transaction) {
                        DDLogDebug(@"%@ decrypted pre-key whisper message", self.logTag);
                        successBlock(plaintextData, transaction);
                    }
                    failureBlock:^(NSError *_Nullable error) {
                        DDLogError(@"%@ decrypting pre-key whisper message from address: %@ failed "
                                   @"with error: %@",
                            self.logTag,
                            envelopeAddress(envelope),
                            error);
                        failureBlock();
                    }];
                // Return to avoid double-acknowledging.
                return;
            }
            // These message types don't have a payload to decrypt.
            case SSKEnvelopeTypeReceipt:
            case SSKEnvelopeTypeKeyExchange:
            case SSKEnvelopeTypeUnknown: {
                [self.dbConnection readWriteWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
                    successBlock(nil, transaction);
                }];
                // Return to avoid double-acknowledging.
                return;
            }
            default:
                DDLogWarn(@"Received unhandled envelope type: %d", (int)envelope.type);
                break;
        }
    } @catch (NSException *exception) {
        OWSFailDebug(@"%@ Received an invalid envelope: %@", self.logTag, exception.debugDescription);

//        // FIXME: Supressing this message for now
//        [[OWSPrimaryStorage.sharedManager newDatabaseConnection]
//            readWriteWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
//                TSErrorMessage *errorMessage = [TSErrorMessage corruptedMessageInUnknownThread];
//                [[TextSecureKitEnv sharedEnv].notificationsManager notifyUserForThreadlessErrorMessage:errorMessage
//                                                                                           transaction:transaction];
//            }];
    }

    failureBlock();
}

- (void)decryptSecureMessage:(SSKEnvelope *)envelope
                successBlock:(DecryptSuccessBlock)successBlock
                failureBlock:(void (^)(NSError *_Nullable error))failureBlock
{
    OWSAssert(envelope);
    OWSAssert(successBlock);
    OWSAssert(failureBlock);
    
    [self decryptEnvelope:envelope
           cipherTypeName:@"Secure Message"
       cipherMessageBlock:^id<CipherMessage> _Nonnull(NSData * _Nonnull encryptedData) {
           return [[WhisperMessage alloc] init_throws_withData:encryptedData];
       }
             successBlock:successBlock
             failureBlock:failureBlock];
}

- (void)decryptPreKeyBundle:(SSKEnvelope *)envelope
               successBlock:(DecryptSuccessBlock)successBlock
               failureBlock:(void (^)(NSError *_Nullable error))failureBlock
{
    OWSAssert(envelope);
    OWSAssert(successBlock);
    OWSAssert(failureBlock);

    // Check whether we need to refresh our PreKeys every time we receive a PreKeyWhisperMessage.
    [TSPreKeyManager checkPreKeys];

    [self decryptEnvelope:envelope
            cipherTypeName:@"PreKey Bundle"
        cipherMessageBlock:^id<CipherMessage> _Nonnull(NSData * _Nonnull encryptedData) {
            return [[PreKeyWhisperMessage alloc] init_throws_withData:encryptedData];
        }
              successBlock:successBlock
              failureBlock:failureBlock];
}

- (void)decryptEnvelope:(SSKEnvelope *)envelope
         cipherTypeName:(NSString *)cipherTypeName
     cipherMessageBlock:(id<CipherMessage> (^_Nonnull)(NSData *))cipherMessageBlock
           successBlock:(DecryptSuccessBlock)successBlock
           failureBlock:(void (^)(NSError *_Nullable error))failureBlock
{
    OWSAssert(envelope);
    OWSAssert(cipherTypeName.length > 0);
    OWSAssert(cipherMessageBlock);
    OWSAssert(successBlock);
    OWSAssert(failureBlock);

    OWSPrimaryStorage *primaryStorage = self.primaryStorage;
    NSString *recipientId = envelope.source;
    int deviceId = envelope.sourceDevice;

    // DEPRECATED - Remove `legacyMessage` after all clients have been upgraded.
    NSData *encryptedData = envelope.content ?: envelope.legacyMessage;
    if (!encryptedData) {
        failureBlock(nil);
        return;
    }

    [self.dbConnection
        asyncReadWriteWithBlock:^(YapDatabaseReadWriteTransaction *_Nonnull transaction) {
            @try {
                id<CipherMessage> cipherMessage = cipherMessageBlock(encryptedData);
                SessionCipher *cipher = [[SessionCipher alloc] initWithSessionStore:primaryStorage
                                                                        preKeyStore:primaryStorage
                                                                  signedPreKeyStore:primaryStorage
                                                                   identityKeyStore:self.identityManager
                                                                        recipientId:recipientId
                                                                           deviceId:deviceId];

                NSData *plaintextData = [[cipher throws_decrypt:cipherMessage protocolContext:transaction] removePadding];
                successBlock(plaintextData, transaction);
            } @catch (NSException *exception) {
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    [self processException:exception envelope:envelope];
                    NSString *errorDescription = [NSString
                        stringWithFormat:@"Exception while decrypting %@: %@", cipherTypeName, exception.description];
                    NSError *error = OWSErrorWithCodeDescription(OWSErrorCodeFailedToDecryptMessage, errorDescription);
                    failureBlock(error);
                });
            }
        }];
}

- (void)processException:(NSException *)exception envelope:(SSKEnvelope *)envelope
{
    DDLogError(@"%@ Got exception: %@ of type: %@ with reason: %@",
               self.logTag,
               exception.description,
               exception.name,
               exception.reason);
    
    
    [self.dbConnection readWriteWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
        TSErrorMessage *errorMessage;
        
        if ([exception.name isEqualToString:NoSessionException]) {
            // Supressing this messaeg.
//            errorMessage = [TSErrorMessage missingSessionWithEnvelope:envelope withTransaction:transaction];
            return;
        } else if ([exception.name isEqualToString:InvalidKeyException]) {
            errorMessage = [TSErrorMessage invalidKeyExceptionWithEnvelope:envelope withTransaction:transaction];
        } else if ([exception.name isEqualToString:InvalidKeyIdException]) {
            errorMessage = [TSErrorMessage invalidKeyExceptionWithEnvelope:envelope withTransaction:transaction];
        } else if ([exception.name isEqualToString:DuplicateMessageException]) {
            // Duplicate messages are dismissed
            return;
        } else if ([exception.name isEqualToString:InvalidVersionException]) {
            errorMessage = [TSErrorMessage invalidVersionWithEnvelope:envelope withTransaction:transaction];
        } else if ([exception.name isEqualToString:UntrustedIdentityKeyException]) {
            // Should no longer get here, since we now record the new identity for incoming messages.
            OWSFailDebug(@"%@ Failed to trust identity on incoming message from: %@", self.logTag, envelopeAddress(envelope));
            return;
        } else {
            errorMessage = [TSErrorMessage corruptedMessageWithEnvelope:envelope withTransaction:transaction];
        }
        
        OWSAssert(errorMessage);
        if (errorMessage != nil) {
            [errorMessage saveWithTransaction:transaction];
            [self notifyUserForErrorMessage:errorMessage envelope:envelope transaction:transaction];
        }
    }];
}

- (void)notifyUserForErrorMessage:(TSErrorMessage *)errorMessage
                         envelope:(SSKEnvelope *)envelope
                      transaction:(YapDatabaseReadWriteTransaction *)transaction
{
    TSThread *thread = [TSThread getOrCreateThreadWithParticipants:@[envelope.source, TSAccountManager.localUID]
                                                       transaction:transaction];
    [[TextSecureKitEnv sharedEnv].notificationsManager notifyUserForErrorMessage:errorMessage
                                                                          thread:thread
                                                                     transaction:transaction];
}

@end

NS_ASSUME_NONNULL_END
