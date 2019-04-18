//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import "ConversationViewController.h"

NS_ASSUME_NONNULL_BEGIN

@class AccountManager;
@class ConferenceCallService;
@class CallUIAdapter;
@class HomeViewController;
@class NotificationsManager;
@class OWSMessageFetcherJob;
@class OWSNavigationController;
@class OutboundCallInitiator;
@class TSThread;

@interface RelayApp : NSObject

@property (nonatomic, nullable, weak) HomeViewController *homeViewController;
@property (nonatomic, nullable, weak) OWSNavigationController *signUpFlowNavigationController;

// TODO: Convert to singletons?
@property (nonatomic, readonly) ConferenceCallService *callService;
@property (nonatomic, readonly) OWSMessageFetcherJob *messageFetcherJob;
@property (nonatomic, readonly) NotificationsManager *notificationsManager;
@property (nonatomic, readonly) AccountManager *accountManager;

- (instancetype)init NS_UNAVAILABLE;

+ (instancetype)sharedApp;

#pragma mark - View Convenience Methods

- (void)presentConversationForThreadId:(NSString *)threadId
                                action:(nullable ConversationViewAction)action
                        focusMessageId:(nullable NSString *)focusMessageId;

#pragma mark - Methods

+ (void)resetAppData;

+ (void)clearAllNotifications;

@end

NS_ASSUME_NONNULL_END
