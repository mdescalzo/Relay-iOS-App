//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

NS_ASSUME_NONNULL_BEGIN

@class AFHTTPSessionManager;
@class OWSPrimaryStorage;
@class TSAccountManager;

@interface OWSSignalService : NSObject

/// For interacting with the Signal Service
@property (nonatomic, readonly) AFHTTPSessionManager *signalServiceSessionManager;

/// For uploading avatar assets.
//@property (nonatomic, readonly) AFHTTPSessionManager *CDNSessionManager;

+ (instancetype)sharedInstance;

- (instancetype)init NS_UNAVAILABLE;

#pragma mark - Censorship Circumvention


@end

NS_ASSUME_NONNULL_END
