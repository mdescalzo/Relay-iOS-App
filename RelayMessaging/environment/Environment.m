//
//  Copyright (c) 2017 Open Whisper Systems. All rights reserved.
//

#import "Environment.h"
#import "DebugLogger.h"


NSString *const FLRelayWipeAndReturnToRegistrationNotification = @"FLRelayWipeAndReturnToRegistrationNotification";

@import RelayStorage;

static Environment *sharedEnvironment = nil;

@interface Environment ()

@property (nonatomic) FLContactsManager *contactsManager;
@property (nonatomic) TSNetworkManager *networkManager;
@property (nonatomic) MessageSender *messageSender;
@property (nonatomic) OWSPreferences *preferences;
@property (nonatomic) ThreadManager *threadManager;

@end

#pragma mark -

@implementation Environment

+ (Environment *)current
{
    OWSAssertDebug(sharedEnvironment);

    return sharedEnvironment;
}

+ (void)setCurrent:(Environment *)environment
{
    // The main app environment should only be set once.
    //
    // App extensions may be opened multiple times in the same process,
    // so statics will persist.
    OWSAssertDebug(!sharedEnvironment || !CurrentAppContext().isMainApp);
    OWSAssertDebug(environment);

    sharedEnvironment = environment;
}

+ (void)clearCurrentForTests
{
    sharedEnvironment = nil;
}

- (instancetype)initWithContactsManager:(FLContactsManager *)contactsManager
                         networkManager:(TSNetworkManager *)networkManager
                          messageSender:(MessageSender *)messageSender
{
    self = [super init];
    if (!self) {
        return self;
    }

    _contactsManager = contactsManager;
    _networkManager = networkManager;
    _messageSender = messageSender;
    _threadManager = ThreadManager.sharedManager;

    OWSSingletonAssert();

    return self;
}

- (FLContactsManager *)contactsManager
{
    OWSAssertDebug(_contactsManager);

    return _contactsManager;
}

- (TSNetworkManager *)networkManager
{
    OWSAssertDebug(_networkManager);

    return _networkManager;
}

- (MessageSender *)messageSender
{
    OWSAssertDebug(_messageSender);

    return _messageSender;
}

+ (OWSPreferences *)preferences
{
    OWSAssertDebug([Environment current].preferences);

    return [Environment current].preferences;
}

// TODO: Convert to singleton?
- (OWSPreferences *)preferences
{
    @synchronized(self)
    {
        if (!_preferences) {
            _preferences = [OWSPreferences new];
        }
    }

    return _preferences;
}

@end
