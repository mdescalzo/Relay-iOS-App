//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import "Release.h"
#import "Environment.h"
#import <RelayMessaging/RelayMessaging-Swift.h>

@import RelayStorage

@implementation Release

+ (Environment *)releaseEnvironment
{
    static Environment *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // Order matters here.
        StorageManager *primaryStorage = [StorageManager shared];
        TSNetworkManager *networkManager = [TSNetworkManager sharedManager];
        UserManager *userManager = [UserManager shared];
        MessageSender *messageSender = [[MessageSender alloc] initWithNetworkManager:networkManager
                                                                            primaryStorage:primaryStorage
                                                                           contactsManager:contactsManager];

        instance = [[Environment alloc] initWithContactsManager:contactsManager
                                                 networkManager:networkManager
                                                  messageSender:messageSender];
    });
    return instance;
}

@end
