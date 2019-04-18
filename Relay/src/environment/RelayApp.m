//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import "RelayApp.h"
#import "ConversationViewController.h"
#import "HomeViewController.h"
#import "Relay-Swift.h"

@import RelayServiceKit;
@import RelayMessaging;

NS_ASSUME_NONNULL_BEGIN

@interface RelayApp ()

@property (nonatomic) ConferenceCallService *conferenceCallService;
@property (nonatomic) OutboundCallInitiator *outboundCallInitiator;
@property (nonatomic) OWSMessageFetcherJob *messageFetcherJob;
@property (nonatomic) NotificationsManager *notificationsManager;
@property (nonatomic) AccountManager *accountManager;

@end

#pragma mark -

@implementation RelayApp

+ (instancetype)sharedApp
{
    static RelayApp *sharedApp = nil;
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

- (void)presentConversationForThreadId:(NSString *)threadId
                                action:(ConversationViewAction)action
                        focusMessageId:(nullable NSString *)focusMessageId
{
    OWSAssertDebug(threadId.length > 0);
    
    DispatchMainThreadSafe(^{
        __block TSThread *thread = nil;
        [OWSPrimaryStorage.dbReadConnection readWithBlock:^(YapDatabaseReadTransaction * _Nonnull transaction) {
            thread = [TSThread fetchObjectWithUniqueID:threadId transaction:transaction];
        }];
        
        [self presentConversationForThread:thread action:action];
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
    [RelayApp clearAllNotifications];
    [OWSPrimaryStorage.sharedManager.dbReadWriteConnection asyncReadWriteWithBlock:^(YapDatabaseReadWriteTransaction * _Nonnull transaction) {
        [transaction removeAllObjectsInAllCollections];
    }];
}

@end

NS_ASSUME_NONNULL_END
