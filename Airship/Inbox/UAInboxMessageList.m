/*
Copyright 2009-2014 Urban Airship Inc. All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
list of conditions and the following disclaimer.

2. Redistributions in binaryform must reproduce the above copyright notice,
this list of conditions and the following disclaimer in the documentation
and/or other materials provided withthe distribution.

THIS SOFTWARE IS PROVIDED BY THE URBAN AIRSHIP INC ``AS IS'' AND ANY EXPRESS OR
IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO
EVENT SHALL URBAN AIRSHIP INC OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE
OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*/

#import "UAInboxMessageList+Internal.h"

#import "UAirship.h"
#import "UAConfig.h"
#import "UADisposable.h"
#import "UAInbox.h"
#import "UAInboxAPIClient.h"
#import "UAInboxMessageListObserver.h"
#import "UAInboxMessageListDelegate.h"
#import "UAInboxMessage+Internal.h"
#import "UAInboxDBManager+Internal.h"
#import "UAUtils.h"
#import "UAUser.h"
#import "UAHTTPConnection.h"
#import "UAURLProtocol.h"

NSString * const UAInboxMessageListWillUpdateNotification = @"com.urbanairship.notification.message_list_will_update";
NSString * const UAInboxMessageListUpdatedNotification = @"com.urbanairship.notification.message_list_updated";

/*
 * Private methods
 */
@interface UAInboxMessageList()

- (void)loadSavedMessages;

@property(nonatomic, assign) BOOL isRetrieving;

@end

@implementation UAInboxMessageList

#pragma mark Create Inbox

- (instancetype)init {
    self = [super init];

    if (self) {
        self.unreadCount = -1;
        self.isBatchUpdating = NO;
    }
    return self;
}

- (void)dealloc {
    self.messages = nil;
}


+ (UAInboxMessageList *)shared {

    return [UAInbox shared].messageList;
}

#pragma mark NSNotificationCenter helper methods

- (void)sendMessageListWillUpdateNotification {
    [[NSNotificationCenter defaultCenter] postNotificationName:UAInboxMessageListWillUpdateNotification object:nil];
}

- (void)sendMessageListUpdatedNotification {
    [[NSNotificationCenter defaultCenter] postNotificationName:UAInboxMessageListUpdatedNotification object:nil];
}

#pragma mark Update/Delete/Mark Messages
- (void)loadSavedMessagesWithCompletion:(void(^)(NSArray *messages))completion {
    UAInboxDBManager *inboxDBManager = [UAInboxDBManager shared];
    [inboxDBManager performBackgroundActionAndSave:^(NSManagedObjectContext *context) {
        [inboxDBManager deleteExpiredMessagesInContext:context];
    } completion:^(NSError *saveError) {
        [inboxDBManager getMessagesWithCompletion:^(NSArray *messages){
            
            self.messages = [messages mutableCopy];
            
            UA_LDEBUG(@"Loaded saved messages: %@.", self.messages);
            
            if (completion) {
                completion(self.messages);
            }
        }];
    }];
}

- (void)setUnreadCountForMessages:(NSArray *)messages {
    NSIndexSet *unreadIndexes =
    [messages indexesOfObjectsPassingTest:^BOOL(UAInboxMessage *msg,
                                                NSUInteger idx,
                                                BOOL *stop) {
        return msg.unread;
    }];
    
    self.unreadCount = [unreadIndexes count];
    
    for (UAInboxMessage *msg in messages) {
        msg.inbox = self;
    }
}

- (void)loadSavedMessages {
    UAInboxDBManager *inboxDBManager = [UAInboxDBManager shared];
    [inboxDBManager deleteExpiredMessages];
    NSMutableArray *savedMessages = [[inboxDBManager getMessages] mutableCopy];
    
    self.messages = savedMessages;
    UA_LDEBUG(@"Loaded saved messages: %@.", self.messages);
}

- (UADisposable *)retrieveMessageListWithSuccessBlock:(UAInboxMessageListCallbackBlock)successBlock
                                  withFailureBlock:(UAInboxMessageListCallbackBlock)failureBlock {
    if (![[UAUser defaultUser] defaultUserCreated]) {
        return nil;
    }

    UA_LDEBUG("Retrieving message list.");

    [self notifyObservers: @selector(messageListWillLoad)];
    [self sendMessageListWillUpdateNotification];
  
  self.isRetrieving = YES;
  
  __block BOOL isCallbackCancelled = NO;
  
  UADisposable *disposable = [UADisposable disposableWithBlock:^{
    isCallbackCancelled = YES;
  }];
[self loadSavedMessagesWithCompletion:^(NSArray *messages) {
    [self.client retrieveMessageListOnSuccess:^(NSInteger status, NSArray *messages, NSInteger unread) {
        
        void (^saveCompletion)(NSError *saveError) = ^(NSError *saveError){
            self.isRetrieving = NO;
            
            UA_LDEBUG(@"Retrieve message list succeeded with messages: %@", self.messages);
            if (successBlock && !isCallbackCancelled) {
                successBlock();
            }
            
            [self notifyObservers:@selector(messageListLoaded)];
            [self sendMessageListUpdatedNotification];
        };

        if (status == 200) {
            UA_LDEBUG(@"Refreshing message list.");

            UAInboxDBManager *inboxDBManager = [UAInboxDBManager shared];
            
            [inboxDBManager performBackgroundActionAndSave:^(NSManagedObjectContext *context) {
                NSMutableSet *responseMessageIDs = [NSMutableSet set];
                
                // Convert dictionary to objects for convenience
                for (NSDictionary *message in messages) {
                    if (![inboxDBManager updateMessageWithDictionary:message context:context]) {
                        [inboxDBManager addMessageFromDictionary:message
                                                         context:context];
                    }
                    
                    NSString *messageID = [message valueForKey:@"message_id"];
                    if (messageID) {
                        [responseMessageIDs addObject:messageID];
                    }
                }
                
                // Delete server side deleted messages
                NSMutableSet *messagesToDelete = [[inboxDBManager messageIDsInContext:context] mutableCopy];
                [messagesToDelete minusSet:responseMessageIDs];
                [inboxDBManager deleteMessagesWithIDs:messagesToDelete context:context];
            } completion:^(NSError *saveError){
                [self loadSavedMessagesWithCompletion:^(NSArray *messages) {
                    saveCompletion(saveError);
                }];
            }];
        } else {
            saveCompletion(nil);
        }
      } onFailure:^(UAHTTPRequest *request){
        self.isRetrieving = NO;
        
        UA_LDEBUG(@"Retrieve message list failed with status: %ld", (long)request.response.statusCode);
        if (failureBlock && !isCallbackCancelled) {
          failureBlock();
        }
        
        [self notifyObservers:@selector(inboxLoadFailed)];
        [self sendMessageListUpdatedNotification];
      }];
    }];

    return disposable;
}

- (UADisposable *)retrieveMessageListWithDelegate:(id<UAInboxMessageListDelegate>)delegate {
    __weak id<UAInboxMessageListDelegate> weakDelegate = delegate;

    return [self retrieveMessageListWithSuccessBlock:^{
        id<UAInboxMessageListDelegate> strongDelegate = weakDelegate;
        if ([strongDelegate respondsToSelector:@selector(messageListLoadSucceeded)]) {
            [strongDelegate messageListLoadSucceeded];
        }
    } withFailureBlock:^{
        id<UAInboxMessageListDelegate> strongDelegate = weakDelegate;
        if ([strongDelegate respondsToSelector:@selector(messageListLoadFailed)]){
            [strongDelegate messageListLoadFailed];
        }
    }];
}

- (void)retrieveMessageList {
    [self retrieveMessageListWithSuccessBlock:nil withFailureBlock:nil];
}

- (UADisposable *)performBatchUpdateCommand:(UABatchUpdateCommand)command
                        withMessageIndexSet:(NSIndexSet *)messageIndexSet
                           withSuccessBlock:(UAInboxMessageListCallbackBlock)successBlock
                           withFailureBlock:(UAInboxMessageListCallbackBlock)failureBlock {
    if (command != UABatchDeleteMessages && command != UABatchReadMessages) {
        UA_LWARN(@"Unable to perform batch update with invalid command type: %d", command);
        return nil;
    }

    NSArray *updateMessageArray = [self.messages objectsAtIndexes:messageIndexSet];

    self.isBatchUpdating = YES;
    [self notifyObservers: @selector(messageListWillLoad)];
    [self sendMessageListWillUpdateNotification];

    __block BOOL isCallbackCancelled = NO;

    UADisposable *disposable = [UADisposable disposableWithBlock:^{
        isCallbackCancelled = YES;
    }];


    void (^fail)(UAHTTPRequest *) = ^(UAHTTPRequest *request){
        self.isBatchUpdating = NO;
        UA_LDEBUG(@"Perform batch update failed with status: %ld", (long)request.response.statusCode);
        if (failureBlock && !isCallbackCancelled) {
            failureBlock();
        }
        [self sendMessageListUpdatedNotification];
    };

    void (^succeed)(void) = ^{
        [self loadSavedMessagesWithCompletion:^(NSArray *messages) {
            self.isBatchUpdating = NO;

            if (successBlock && !isCallbackCancelled) {
                successBlock();
            }
            
            [self sendMessageListUpdatedNotification];
        }];
    };

    NSArray *updateMessageDataObjectIDs = [updateMessageArray valueForKeyPath:@"data.objectID"];
    UAInboxDBManager *dbManager = [UAInboxDBManager shared];

    if (command == UABatchDeleteMessages) {
        UA_LDEBUG("Deleting messages: %@", updateMessageArray);
        [self.client performBatchDeleteForMessages:updateMessageArray onSuccess:^{
            [dbManager performBackgroundActionAndSave:^(NSManagedObjectContext *context) {
                NSArray *messagesToDelete = [self managedObjectsForObjectIDs:updateMessageDataObjectIDs
                                                                     context:context];
                [dbManager deleteMessages:updateMessageArray
                                  context:context];
            } completion:^(NSError *saveError) {
                [self notifyObservers:@selector(batchDeleteFinished)];
                succeed();
            }];
        } onFailure:^(UAHTTPRequest *request){
            [self notifyObservers:@selector(batchDeleteFailed)];
            fail(request);
        }];

    } else if (command == UABatchReadMessages) {
        UA_LDEBUG("Marking messages as read: %@", updateMessageArray);
        [self.client performBatchMarkAsReadForMessages:updateMessageArray onSuccess:^{
            [dbManager performBackgroundActionAndSave:^(NSManagedObjectContext *context) {
                NSArray *messagesToMarkRead = [self managedObjectsForObjectIDs:updateMessageDataObjectIDs
                                                                       context:context];
                
                [dbManager markMessagesRead:messagesToMarkRead];
            } completion:^(NSError *saveError) {
                [self notifyObservers:@selector(batchMarkAsReadFinished)];
                succeed();
            }];
        } onFailure:^(UAHTTPRequest *request){
            [self notifyObservers:@selector(batchMarkAsReadFailed)];
            fail(request);
        }];
    }

    return disposable;
}

- (UADisposable *)performBatchUpdateCommand:(UABatchUpdateCommand)command
              withMessageIndexSet:(NSIndexSet *)messageIndexSet
                     withDelegate:(id<UAInboxMessageListDelegate>)delegate {

    __weak id<UAInboxMessageListDelegate> weakDelegate = delegate;

    return [self performBatchUpdateCommand:command withMessageIndexSet:messageIndexSet withSuccessBlock:^{
        id<UAInboxMessageListDelegate> strongDelegate = weakDelegate;
        if (command == UABatchDeleteMessages) {
            if ([strongDelegate respondsToSelector:@selector(batchDeleteFinished)]) {
                [strongDelegate batchDeleteFinished];
            }
        } else if (command == UABatchReadMessages) {
            if ([strongDelegate respondsToSelector:@selector(batchMarkAsReadFinished)]) {
                [strongDelegate batchMarkAsReadFinished];
            }
        }
    } withFailureBlock:^{
        id<UAInboxMessageListDelegate> strongDelegate = weakDelegate;
        if (command == UABatchDeleteMessages) {
            if ([strongDelegate respondsToSelector:@selector(batchDeleteFailed)]) {
                [strongDelegate batchDeleteFailed];
            }
        } else if (command == UABatchReadMessages) {
            if ([strongDelegate respondsToSelector:@selector(batchMarkAsReadFailed)]) {
                [strongDelegate batchMarkAsReadFailed];
            }
        }
    }];
}

- (void)performBatchUpdateCommand:(UABatchUpdateCommand)command withMessageIndexSet:(NSIndexSet *)messageIndexSet {
    [self performBatchUpdateCommand:command
                withMessageIndexSet:messageIndexSet
                   withSuccessBlock:nil
                   withFailureBlock:nil];
}

#pragma mark -
#pragma mark CoreData

- (NSArray *)managedObjectsForObjectIDs:(NSArray *)objectIDs
                                context:(NSManagedObjectContext *)context {
    NSMutableArray *objectsInContext = [NSMutableArray array];
    for (NSManagedObjectID *objectID in objectIDs) {
        NSError *objectIDError = nil;
        id existingObject = [context existingObjectWithID:objectID
                                                    error:&objectIDError];
        
        if (existingObject) {
            [objectsInContext addObject:existingObject];
        } else if (objectIDError) {
            UA_LERR(@"Error fetching existing object with ID (%@): %@, %@",objectID, objectIDError, [objectIDError userInfo]);
        }
    }
    
    return objectsInContext;
}

#pragma mark -
#pragma mark Get messages

- (NSUInteger)messageCount {
    return [self.messages count];
}

- (UAInboxMessage *)messageForID:(NSString *)mid {
    for (UAInboxMessage *msg in self.messages) {
        if ([msg.messageID isEqualToString:mid]) {
            return msg;
        }
    }
    return nil;
}

- (UAInboxMessage *)messageAtIndex:(NSUInteger)index {
    if (index >= [self.messages count]) {
        UA_LWARN("Load message(index=%lu, count=%lu) error.", (unsigned long)index, (unsigned long)[self.messages count]);
        return nil;
    }
    return [self.messages objectAtIndex:index];
}

- (NSUInteger)indexOfMessage:(UAInboxMessage *)message {
    return [self.messages indexOfObject:message];
}

#pragma mark -
#pragma mark set messages
- (void)setMessages:(NSMutableArray *)messages {
    // Sort the messages by date
    if (messages.count > 0) {
        NSSortDescriptor* dateDescriptor = [[NSSortDescriptor alloc] initWithKey:@"messageSent"
                                                                       ascending:NO];
        NSSortDescriptor *messageIDDescriptor = [[NSSortDescriptor alloc] initWithKey:@"messageID"
                                                                            ascending:YES];
        NSArray *sortDescriptors = @[dateDescriptor, messageIDDescriptor];
        [messages sortUsingDescriptors:sortDescriptors];
    }

    // Add messsage's body url to the cachable urls
    for (UAInboxMessage *message in messages) {
        [UAURLProtocol addCachableURL:message.messageBodyURL];
    }
    
    [self setUnreadCountForMessages:messages];

    _messages = messages;
}


@end
