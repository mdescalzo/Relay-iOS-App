//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import "Release.h"
#import "Environment.h"
#import <RelayMessaging/RelayMessaging-Swift.h>

@import RelayServiceKit;

@implementation Release

+ (Environment *)releaseEnvironment
{
    static Environment *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // Order matters here.
        OWSPrimaryStorage *primaryStorage = [OWSPrimaryStorage sharedManager];
        TSNetworkManager *networkManager = [TSNetworkManager sharedManager];
        FLContactsManager *contactsManager = [FLContactsManager shared];
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
