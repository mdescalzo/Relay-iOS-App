//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import "SignalApp.h"
#import "ConversationViewController.h"
#import "HomeViewController.h"
#import "Relay-Swift.h"

@import RelayServiceKit;
@import RelayMessaging;

NS_ASSUME_NONNULL_BEGIN

@interface SignalApp ()

@property (nonatomic) ConferenceCallService *conferenceCallService;
@property (nonatomic) OutboundCallInitiator *outboundCallInitiator;
@property (nonatomic) OWSMessageFetcherJob *messageFetcherJob;
@property (nonatomic) NotificationsManager *notificationsManager;
@property (nonatomic) AccountManager *accountManager;

@end

#pragma mark -

@implementation SignalApp

+ (instancetype)sharedApp
{
    static SignalApp *sharedApp = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedApp = [[self alloc] initDefault];
    });
    return sharedApp;
}

- (instancetype)initDefault
{
    self = [super init];

    if (!self) {
        return self;
    }

    OWSSingletonAssert();
    
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(resetAppDataReturnToRegistration)
                                               name:FLRelayWipeAndReturnToRegistrationNotification
                                             object:nil];
    
    return self;
}

-(void)dealloc
{
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

#pragma mark - Singletons

- (ConferenceCallService *)conferenceCallService
{
    @synchronized(self)
    {
        if (!_conferenceCallService) {
            _conferenceCallService = ConferenceCallService.shared;
        }
    }

    return _conferenceCallService;
}

- (OWSMessageFetcherJob *)messageFetcherJob
{
    @synchronized(self)
    {
        if (!_messageFetcherJob) {
            _messageFetcherJob =
                [[OWSMessageFetcherJob alloc] initWithMessageReceiver:[OWSMessageReceiver sharedInstance]
                                                       networkManager:Environment.current.networkManager
                                                        signalService:[OWSSignalService sharedInstance]];
        }
    }
    return _messageFetcherJob;
}

- (NotificationsManager *)notificationsManager
{
    @synchronized(self)
    {
        if (!_notificationsManager) {
            _notificationsManager = [NotificationsManager new];
        }
    }

    return _notificationsManager;
}

- (AccountManager *)accountManager
{
    @synchronized(self)
    {
        if (!_accountManager) {
            _accountManager = [[AccountManager alloc] initWithTextSecureAccountManager:[TSAccountManager sharedInstance]
                                                                           preferences:Environment.current.preferences];
        }
    }

    return _accountManager;
}

#pragma mark - View Convenience Methods

- (void)presentConversationForRecipientId:(NSString *)recipientId
{
    [self presentConversationForRecipientId:recipientId action:ConversationViewActionNone];
}

- (void)presentConversationForRecipientId:(NSString *)recipientId action:(ConversationViewAction)action
{
    DispatchMainThreadSafe(^{
        __block TSThread *thread = nil;
        [OWSPrimaryStorage.dbReadWriteConnection
            readWriteWithBlock:^(YapDatabaseReadWriteTransaction *_Nonnull transaction) {
                
                NSArray<TSThread *> *possibleThreads = [TSThread threadsContainingParticipant:recipientId transaction:transaction];
                
                for (TSThread *athread in possibleThreads) {
                    if ([recipientId isEqualToString:athread.otherParticipantId]) {
                        thread = athread;
                        break;
                    }
                }
                
                if (thread == nil) {
                    thread = [TSThread getOrCreateThreadWithParticipants:@[recipientId, TSAccountManager.localUID]
                                                             transaction:transaction];
                }
            }];
        [self presentConversationForThread:thread action:action];
    });
}

- (void)presentConversationForThreadId:(NSString *)threadId
{
    [self presentConversationForThreadId:threadId action:ConversationViewActionNone];
}

- (void)presentConversationForThreadId:(NSString *)threadId action:(ConversationViewAction)action
{
    OWSAssert(threadId.length > 0);
    
    DispatchMainThreadSafe(^{
        __block TSThread *thread = nil;
        [OWSPrimaryStorage.dbReadWriteConnection readWriteWithBlock:^(YapDatabaseReadWriteTransaction * _Nonnull transaction) {
            thread = [TSThread getOrCreateThreadWithId:threadId transaction:transaction];
        }];
        
        [self presentConversationForThread:thread action:action];
    });
}

- (void)presentConversationForThread:(TSThread *)thread
{
    [self presentConversationForThread:thread action:ConversationViewActionNone];
}

- (void)presentConversationForThread:(TSThread *)thread action:(ConversationViewAction)action
{
    [self presentConversationForThread:thread action:action focusMessageId:nil];
}

- (void)presentConversationForThread:(TSThread *)thread
                              action:(ConversationViewAction)action
                      focusMessageId:(nullable NSString *)focusMessageId
{
    OWSAssertIsOnMainThread();

    DDLogInfo(@"%@ %s", self.logTag, __PRETTY_FUNCTION__);

    if (!thread) {
        OWSFail(@"%@ Can't present nil thread.", self.logTag);
        return;
    }

    DispatchMainThreadSafe(^{
        UIViewController *frontmostVC = [[UIApplication sharedApplication] frontmostViewController];

        if ([frontmostVC isKindOfClass:[ConversationViewController class]]) {
            ConversationViewController *conversationVC = (ConversationViewController *)frontmostVC;
            if ([conversationVC.thread.uniqueId isEqualToString:thread.uniqueId]) {
                [conversationVC popKeyBoard];
                return;
            }
        }

        [self.homeViewController presentThread:thread action:action focusMessageId:focusMessageId];
    });
}

- (void)didChangeCallLoggingPreference:(NSNotification *)notification
{
}

#pragma mark - Methods

+ (void)resetAppData
{
    // This _should_ be wiped out below.
    DDLogError(@"%@ %s", self.logTag, __PRETTY_FUNCTION__);
    [DDLog flushLog];

    [OWSStorage resetAllStorage];
    [OWSUserProfile resetProfileStorage];
    [Environment.preferences clear];

    [self clearAllNotifications];

    [DebugLogger.sharedLogger wipeLogs];
    exit(0);
}

+ (void)clearAllNotifications
{
    DDLogInfo(@"%@ clearAllNotifications.", self.logTag);

    // This will cancel all "scheduled" local notifications that haven't
    // been presented yet.
    [UIApplication.sharedApplication cancelAllLocalNotifications];
    // To clear all already presented local notifications, we need to
    // set the app badge number to zero after setting it to a non-zero value.
    [UIApplication sharedApplication].applicationIconBadgeNumber = 1;
    [UIApplication sharedApplication].applicationIconBadgeNumber = 0;
}

-(void)resetAppDataReturnToRegistration
{
    DispatchSyncMainThreadSafe(^{
        UIStoryboard *storyboard = [UIStoryboard storyboardWithName:@"Login" bundle:[NSBundle mainBundle]];
        UIViewController *viewController = [storyboard instantiateInitialViewController];
        OWSNavigationController *navigationController = [[OWSNavigationController alloc] initWithRootViewController:viewController];
        [UIApplication sharedApplication].delegate.window.rootViewController = navigationController;
    });
    [SignalApp clearAllNotifications];
    [OWSPrimaryStorage.sharedManager.dbReadWriteConnection asyncReadWriteWithBlock:^(YapDatabaseReadWriteTransaction * _Nonnull transaction) {
        [transaction removeAllObjectsInAllCollections];
    }];
}

@end

NS_ASSUME_NONNULL_END
