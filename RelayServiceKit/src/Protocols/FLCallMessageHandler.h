//  Created by Michael Kirk on 12/4/16.
//  Copyright © 2016 Open Whisper Systems. All rights reserved.

NS_ASSUME_NONNULL_BEGIN

@class OWSSignalServiceProtosCallMessageOffer;
@class OWSSignalServiceProtosCallMessageAnswer;
@class OWSSignalServiceProtosCallMessageIceUpdate;
@class OWSSignalServiceProtosCallMessageHangup;
@class OWSSignalServiceProtosCallMessageBusy;

@protocol FLCallMessageHandler <NSObject>

-(void)receivedJoinWithThread:(TSThread *)thread
                     senderId:(NSString *)senderId
               senderDeviceId:(UInt32)senderDeviceId
                 originatorId:(NSString *)originatorId
                       callId:(NSString *)callId;

-(void)receivedOfferWithThread:(TSThread *)thread
                      senderId:(NSString *)senderId
                senderDeviceId:(UInt32)senderDeviceId
                        callId:(NSString *)callId
                        peerId:(NSString *)peerId
            sessionDescription:(NSString *)sessionDescription;

-(void)receivedAcceptOfferWithThread:(TSThread *)thread
                              callId:(NSString *)callId
                              peerId:(NSString *)peerId
                  sessionDescription:(NSString *)sessionDescription;

-(void)receivedIceCandidatesWithThread:(TSThread *)thread
                                callId:(NSString *)callId
                                peerId:(NSString *)peerId
                         iceCandidates:(NSArray *)iceCandidates;

-(void)receivedLeaveWithThread:(TSThread *)thread
                      senderId:(NSString *)senderId
                senderDeviceId:(UInt32)senderDeviceId
                        callId:(NSString *)callId;

@end

NS_ASSUME_NONNULL_END
