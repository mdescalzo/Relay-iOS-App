//  Created by Michael Kirk on 12/4/16.
//  Copyright © 2016 Open Whisper Systems. All rights reserved.

NS_ASSUME_NONNULL_BEGIN

@class OWSSignalServiceProtosCallMessageOffer;
@class OWSSignalServiceProtosCallMessageAnswer;
@class OWSSignalServiceProtosCallMessageIceUpdate;
@class OWSSignalServiceProtosCallMessageHangup;
@class OWSSignalServiceProtosCallMessageBusy;

@protocol FLCallMessageHandler <NSObject>

-(void)receivedOfferWithThreadId:(NSString *)threadId
                          callId:(NSString *)callId
                        senderId:(NSString *)senderId
                          peerId:(NSString *)peerId
                    originatorId:(NSString *)originatorId
              sessionDescription:(NSString *)sessionDescription;

-(void)receivedAcceptOfferWithThreadId:(NSString *)threadId
                                callId:(NSString *)callId
                                peerId:(NSString *)peerId
                    sessionDescription:(NSString *)sessionDescription;

-(void)receivedIceCandidatesWithThreadId:(NSString *)threadId
                                  callId:(NSString *)callId
                                  peerId:(NSString *)peerId
                           iceCandidates:(NSArray *)iceCandidates;

-(void)receivedLeaveWithThreadId:(NSString *)threadId
                          callId:(NSString *)callId
                          peerId:(NSString *)peerId;

@end

NS_ASSUME_NONNULL_END
