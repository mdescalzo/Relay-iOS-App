//
//  Copyright (c) 2017 Open Whisper Systems. All rights reserved.
//

NS_ASSUME_NONNULL_BEGIN

@protocol ContactsManagerProtocol;
@class MessageSender;
@protocol NotificationsProtocol;
@protocol FLCallMessageHandler;
@protocol ProfileManagerProtocol;

@interface TextSecureKitEnv : NSObject

- (instancetype)initWithCallMessageHandler:(id<FLCallMessageHandler>)callMessageHandler
                           contactsManager:(id<ContactsManagerProtocol>)contactsManager
                             messageSender:(MessageSender *)messageSender
                      notificationsManager:(id<NotificationsProtocol>)notificationsManager
                            profileManager:(id<ProfileManagerProtocol>)profileManager NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

+ (instancetype)sharedEnv;
+ (void)setSharedEnv:(TextSecureKitEnv *)env;

@property (nonatomic, readonly) id<FLCallMessageHandler> callMessageHandler;
@property (nonatomic, readonly) id<ContactsManagerProtocol> contactsManager;
@property (nonatomic, readonly) MessageSender *messageSender;
@property (nonatomic, readonly) id<NotificationsProtocol> notificationsManager;
@property (nonatomic, readonly) id<ProfileManagerProtocol> profileManager;

@end

NS_ASSUME_NONNULL_END
