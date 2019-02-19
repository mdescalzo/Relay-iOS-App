//
//  Copyright (c) 2017 Open Whisper Systems. All rights reserved.
//

NS_ASSUME_NONNULL_BEGIN

@class OWSRecipientIdentity;
@class ConferenceCall;

@protocol OWSCallNotificationsAdaptee <NSObject>

- (void)presentIncomingCall:(ConferenceCall *)call callerName:(NSString *)callerName;

- (void)presentMissedCall:(ConferenceCall *)call callerName:(NSString *)callerName;

- (void)presentMissedCallBecauseOfNewIdentity:(ConferenceCall *)call
                                   callerName:(NSString *)callerName
    NS_SWIFT_NAME(presentMissedCallBecauseOfNewIdentity(call:callerName:));

- (void)presentMissedCallBecauseOfNoLongerVerifiedIdentity:(ConferenceCall *)call
                                                callerName:(NSString *)callerName
    NS_SWIFT_NAME(presentMissedCallBecauseOfNoLongerVerifiedIdentity(call:callerName:));

@end

NS_ASSUME_NONNULL_END
