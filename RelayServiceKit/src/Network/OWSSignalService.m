//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import "OWSSignalService.h"
#import "NSNotificationCenter+OWS.h"
#import "OWSCensorshipConfiguration.h"
#import "OWSError.h"
#import "OWSHTTPSecurityPolicy.h"
#import "OWSPrimaryStorage.h"
#import "TSAccountManager.h"
#import "TSConstants.h"
#import "YapDatabaseConnection+OWS.h"
#import "CCSMStorage.h"
#import "SSKAsserts.h"

@import AFNetworking;

NS_ASSUME_NONNULL_BEGIN

NSString *const kOWSPrimaryStorage_OWSSignalService = @"kTSStorageManager_OWSSignalService";

NSString *const kFLTSSURLKey = @"FLTSSURLKey";

@interface OWSSignalService ()

@property (nonatomic, nullable, readonly) OWSCensorshipConfiguration *censorshipConfiguration;

@property (atomic) BOOL hasCensoredPhoneNumber;

@property (nonatomic, nullable) NSString *cachedTSSURL;

@end

#pragma mark -

@implementation OWSSignalService

+ (instancetype)sharedInstance
{
    static OWSSignalService *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] initDefault];
    });
    return sharedInstance;
}

- (instancetype)initDefault
{
    self = [super init];
    if (!self) {
        return self;
    }

    [self observeNotifications];

    OWSSingletonAssert();

    return self;
}

- (void)observeNotifications
{
//    [[NSNotificationCenter defaultCenter] addObserver:self
//                                             selector:@selector(registrationStateDidChange:)
//                                                 name:RegistrationStateDidChangeNotification
//                                               object:nil];
//    [[NSNotificationCenter defaultCenter] addObserver:self
//                                             selector:@selector(localNumberDidChange:)
//                                                 name:kNSNotificationName_LocalUIDDidChange
//                                               object:nil];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (AFHTTPSessionManager *)signalServiceSessionManager
{
    return self.defaultSignalServiceSessionManager;
}

- (AFHTTPSessionManager *)defaultSignalServiceSessionManager
{
    NSURL *baseURL = [[NSURL alloc] initWithString:CCSMStorage.sharedInstance.textSecureURLString];
    OWSAssertDebug(baseURL);
    NSURLSessionConfiguration *sessionConf = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    AFHTTPSessionManager *sessionManager =
        [[AFHTTPSessionManager alloc] initWithBaseURL:baseURL sessionConfiguration:sessionConf];

    sessionManager.securityPolicy = [AFSecurityPolicy defaultPolicy];
//    sessionManager.securityPolicy = [OWSHTTPSecurityPolicy sharedPolicy];
    sessionManager.requestSerializer = [AFJSONRequestSerializer serializer];
    sessionManager.responseSerializer = [AFJSONResponseSerializer serializer];
//    sessionManager.requestSerializer = [AFHTTPRequestSerializer serializer];
//    sessionManager.responseSerializer = [AFHTTPResponseSerializer serializer];

    return sessionManager;
}

-(nullable NSString *)textSecureURL
{
    if (self.cachedTSSURL == nil) {
        self.cachedTSSURL = (NSString *)CCSMStorage.sharedInstance.textSecureURLString;
    }
    return self.cachedTSSURL;
}

-(void)setTextSecureURL:(nullable NSString *)value
{
    [CCSMStorage.sharedInstance setTextSecureURLString:value];
    self.cachedTSSURL = nil;
}

@end

NS_ASSUME_NONNULL_END
