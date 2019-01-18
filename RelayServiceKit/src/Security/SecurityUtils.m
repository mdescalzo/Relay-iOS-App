//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import "SecurityUtils.h"

@import SignalCoreKit;

@implementation SecurityUtils

+ (NSData *)generateRandomBytes:(NSUInteger)length
{
    return [Randomness generateRandomBytes:(int)length];
}

@end
