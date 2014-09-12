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

#import "UAInboxDBManager+Internal.h"
#import "UAInboxMessage+Internal.h"
#import "UAUtils.h"
#import "NSJSONSerialization+UAAdditions.h"
#import <CoreData/CoreData.h>
#import "UAirship.h"
#import "UAConfig.h"

#define kUAInboxDBEntityName @"UAInboxMessage"

@interface UAInboxDBManager ()

@property (nonatomic, strong) NSManagedObjectContext *backgroundContext;

@end

@implementation UAInboxDBManager

// This returns a static alloc -- it makes non-singleton subclasses impossible without swizzling allocWithZone:. :(
SINGLETON_IMPLEMENTATION(UAInboxDBManager)

- (id)init {
    self = [super init];
    if (self) {
        NSString  *databaseName = [NSString stringWithFormat:CORE_DATA_STORE_NAME, [UAirship shared].config.appKey];
        self.storeURL = [[self getStoreDirectoryURL] URLByAppendingPathComponent:databaseName];

        // Delete the old directory if it exists
        [self deleteOldDatabaseIfExists];
        [self createManagedObjectContexts];
    }
    
    return self;
}

#pragma mark - Messages

- (void)getMessagesWithCompletion:(void(^)(NSArray *messages))completion {
  [self.backgroundContext performBlock:^{
    NSArray *messages = [self getMessagesInContext:self.backgroundContext];
    NSArray *messageObjectIDs = [messages valueForKeyPath:@"data.objectID"];
    
    if (completion) {
      dispatch_async(dispatch_get_main_queue(), ^{
        NSMutableArray *mainThreadMessages = [NSMutableArray array];
        for (NSManagedObjectID *objectID in messageObjectIDs) {
          NSError *existingObjectError;
          NSManagedObject *mainThreadObject = [self.managedObjectContext existingObjectWithID:objectID error:&existingObjectError];
          
          if (existingObjectError) {
            UA_LERR(@"Error fetching existing object with ID: %@, %@, %@", objectID, existingObjectError, [existingObjectError userInfo]);
          }
          
          if (mainThreadObject) {
            [mainThreadMessages addObject:[UAInboxMessage messageWithData:mainThreadObject]];
          }
        }
        completion(mainThreadMessages);
      });
    }
  }];
}

- (NSArray *)getMessages {
  return [self getMessagesInContext:self.managedObjectContext];
}

- (NSArray *)getMessagesInContext:(NSManagedObjectContext *)context {
    NSFetchRequest *request = [[NSFetchRequest alloc] init];
    NSEntityDescription *entity = [NSEntityDescription entityForName:kUAInboxDBEntityName
                                              inManagedObjectContext:context];
    [request setEntity:entity];

    NSSortDescriptor *messageSentSortDescriptor = [[NSSortDescriptor alloc] initWithKey:@"messageSent" ascending:NO];
    NSSortDescriptor *messageIDSortDescriptor = [[NSSortDescriptor alloc] initWithKey:@"messageID" ascending:YES];
    NSArray *sortDescriptors = [[NSArray alloc] initWithObjects:messageSentSortDescriptor, messageIDSortDescriptor, nil];
    [request setSortDescriptors:sortDescriptors];

    NSError *error = nil;
    NSArray *resultData = [context executeFetchRequest:request error:&error];
    NSPredicate *isNotDeletedPredicate = [NSPredicate predicateWithFormat:@"%K == NO", @"isDeleted"];
    NSArray *notDeletedResults = [resultData filteredArrayUsingPredicate:isNotDeletedPredicate];
  
    if (notDeletedResults == nil) {
        // Handle the error.
        UALOG(@"No results!");
    }
    NSMutableArray *resultMessages = [NSMutableArray array];

    for (UAInboxMessageData *data in notDeletedResults) {
        [resultMessages addObject:[UAInboxMessage messageWithData:data]];
    }
  
    if (resultMessages == nil) {
        // Handle the error.
        UALOG(@"No results!");
    }

    return resultMessages;
}

- (NSSet *)messageIDs {
  return [self messageIDsInContext:self.managedObjectContext];
}

- (NSSet *)messageIDsInContext:(NSManagedObjectContext *)context {
    NSMutableSet *messageIDs = [NSMutableSet set];
    for (UAInboxMessage *message in [self getMessagesInContext:context]) {
        [messageIDs addObject:message.messageID];
    }

    return messageIDs;
}

- (UAInboxMessage *)addMessageFromDictionary:(NSDictionary *)dictionary
                                     context:(NSManagedObjectContext *)context {
    UAInboxMessageData *data = (UAInboxMessageData *)[NSEntityDescription insertNewObjectForEntityForName:kUAInboxDBEntityName
                                                                                   inManagedObjectContext:context];
    
    dictionary = [dictionary dictionaryWithValuesForKeys:[[dictionary keysOfEntriesPassingTest:^BOOL(id key, id obj, BOOL *stop) {
        return ![obj isEqual:[NSNull null]];
    }] allObjects]];
    
    UAInboxMessage *message = [UAInboxMessage messageWithData:data];
    
    [self updateMessage:message withDictionary:dictionary];
    
    return message;
}

- (UAInboxMessage *)addMessageFromDictionary:(NSDictionary *)dictionary {
  return [self addMessageFromDictionary:dictionary context:self.managedObjectContext];
}

- (BOOL)updateMessageWithDictionary:(NSDictionary *)dictionary {
  return [self updateMessageWithDictionary:dictionary context:self.managedObjectContext];
}

- (BOOL)updateMessageWithDictionary:(NSDictionary *)dictionary context:(NSManagedObjectContext *)context{
    UAInboxMessage *message = [self getMessageWithID:[dictionary objectForKey:@"message_id"]
                                             context:context];
  
    if (!message) {
        return NO;
    }

    [context refreshObject:message.data mergeChanges:YES];
    [self updateMessage:message withDictionary:dictionary];
    return YES;
}

#pragma mark - Delete Messages

- (void)deleteMessages:(NSArray *)messages context:(NSManagedObjectContext *)context {
    for (UAInboxMessage *message in messages) {
        if ([message isKindOfClass:[UAInboxMessage class]]) {
            UALOG(@"Deleting: %@", message.messageID);
            [context deleteObject:message.data];
        }
    }
}

- (void)deleteMessages:(NSArray *)messages {
  [self deleteMessages:messages context:self.managedObjectContext];
}

- (void)markMessagesRead:(NSArray *)messages {
    for (UAInboxMessageData *message in messages) {
        if ([message isKindOfClass:[UAInboxMessageData class]]) {
            message.unread = NO;
        }
    }
}

- (void)deleteMessagesWithIDs:(NSSet *)messageIDs
                      context:(NSManagedObjectContext *)context {
  for (NSString *messageID in messageIDs) {
    UAInboxMessage *message = [self getMessageWithID:messageID context:context];
    
    if (message) {
      UALOG(@"Deleting: %@", messageID);
            [context deleteObject:message.data];
    }
  }
}

- (void)deleteMessagesWithIDs:(NSSet *)messageIDs {
  [self deleteMessagesWithIDs:messageIDs context:self.managedObjectContext];
}

#pragma mark - Core Data

- (void)performBackgroundActionAndSave:(void(^)(NSManagedObjectContext *context))action
                            completion:(void(^)(NSError *saveError))completion {
  [self.backgroundContext performBlock:^{
    action(self.backgroundContext);
    
    [self saveBackgroundContextWithCompletion:completion];
  }];
}

- (void)saveBackgroundContextWithCompletion:(void(^)(NSError *saveError))completion {
  NSError *saveError = nil;
  BOOL hasChanges = [self.backgroundContext hasChanges];
  if (hasChanges && [self.backgroundContext save:&saveError] == NO) {
    UA_LERR(@"Unresolved error %@, %@", saveError, [saveError userInfo]);
  }
  
  if (completion) {
    dispatch_async(dispatch_get_main_queue(), ^{
      completion(saveError);
    });
  }
}


/**
 Returns the managed object context for the application.
 If the context doesn't already exist, it is created and bound to the persistent store coordinator for the application.
 */
- (void)createManagedObjectContexts {
  if (_managedObjectContext == nil) {
    _managedObjectContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
    _managedObjectContext.persistentStoreCoordinator = self.persistentStoreCoordinator;
    _managedObjectContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy;
    
    [[NSNotificationCenter defaultCenter]
     addObserver:self
     selector:@selector(mainContextDidSave:)
     name:NSManagedObjectContextDidSaveNotification
     object:_managedObjectContext];
  }
  
  if (_backgroundContext == nil) {
    _backgroundContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
    _backgroundContext.persistentStoreCoordinator = self.persistentStoreCoordinator;
    _backgroundContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy;
    
    [[NSNotificationCenter defaultCenter]
     addObserver:self
     selector:@selector(backgroundContextDidSave:)
     name:NSManagedObjectContextDidSaveNotification
     object:_backgroundContext];
  }
}

- (void)cleanUpManagedObjectContexts {
  [[NSNotificationCenter defaultCenter]
   removeObserver:self
   name:NSManagedObjectContextDidSaveNotification
   object:_backgroundContext];
  [[NSNotificationCenter defaultCenter]
   removeObserver:self
   name:NSManagedObjectContextDidSaveNotification
   object:_managedObjectContext];
  
  self.backgroundContext = nil;
  self.managedObjectContext = nil;
}

- (void)mainContextDidSave:(NSNotification *)note {
  [self mergeChangesInContext:[self backgroundContext]
              forNotification:note];
}

- (void)backgroundContextDidSave:(NSNotification *)note {
  [self mergeChangesInContext:[self managedObjectContext]
              forNotification:note];
}

- (void)mergeChangesInContext:(NSManagedObjectContext *)context
              forNotification:(NSNotification *)note {
  [context performBlock:^{
    [context mergeChangesFromContextDidSaveNotification:note];
  }];
}

/**
 Returns the managed object model for the application.
 If the model doesn't already exist, it is created from the application's model.
 */
- (NSManagedObjectModel *)managedObjectModel {
    if (_managedObjectModel) {
        return _managedObjectModel;
    }

    _managedObjectModel = [[NSManagedObjectModel alloc] init];
    NSEntityDescription *inboxEntity = [[NSEntityDescription alloc] init];
    [inboxEntity setName:kUAInboxDBEntityName];

    // Note: the class name does not need to be the same as the entity name, but maintaining a consistent
    // entity name is necessary in order to smoothly migrate if the class name changes
    [inboxEntity setManagedObjectClassName:@"UAInboxMessageData"];
    [_managedObjectModel setEntities:@[inboxEntity]];

    NSMutableArray *inboxProperties = [NSMutableArray array];
    [inboxProperties addObject:[self createAttributeDescription:@"messageBodyURL" withType:NSTransformableAttributeType setOptional:true]];
    [inboxProperties addObject:[self createAttributeDescription:@"messageID" withType:NSStringAttributeType setOptional:true]];
    [inboxProperties addObject:[self createAttributeDescription:@"messageSent" withType:NSDateAttributeType setOptional:true]];
    [inboxProperties addObject:[self createAttributeDescription:@"title" withType:NSStringAttributeType setOptional:true]];
    [inboxProperties addObject:[self createAttributeDescription:@"unread" withType:NSBooleanAttributeType setOptional:true]];
    [inboxProperties addObject:[self createAttributeDescription:@"messageURL" withType:NSTransformableAttributeType setOptional:true]];
    [inboxProperties addObject:[self createAttributeDescription:@"messageExpiration" withType:NSDateAttributeType setOptional:true]];

    NSAttributeDescription *extraDescription = [self createAttributeDescription:@"extra" withType:NSTransformableAttributeType setOptional:true];
    [extraDescription setValueTransformerName:@"UAJSONValueTransformer"];
    [inboxProperties addObject:extraDescription];

    NSAttributeDescription *rawMessageObjectDescription = [self createAttributeDescription:@"rawMessageObject" withType:NSTransformableAttributeType setOptional:true];
    [extraDescription setValueTransformerName:@"UAJSONValueTransformer"];
    [inboxProperties addObject:rawMessageObjectDescription];

    [inboxEntity setProperties:inboxProperties];

    return _managedObjectModel;
}

- (NSAttributeDescription *) createAttributeDescription:(NSString *)name
                                               withType:(NSAttributeType)attributeType
                                            setOptional:(BOOL)isOptional {

    NSAttributeDescription *attribute= [[NSAttributeDescription alloc] init];
    [attribute setName:name];
    [attribute setAttributeType:attributeType];
    [attribute setOptional:isOptional];

    return attribute;
}

- (NSPersistentStoreCoordinator *)persistentStoreCoordinator {
    if (_persistentStoreCoordinator) {
        return _persistentStoreCoordinator;
    }
    
    NSError *error = nil;
    _persistentStoreCoordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:self.managedObjectModel];
    if (![_persistentStoreCoordinator addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:self.storeURL options:nil error:&error]) {

        UA_LERR(@"Error adding persistent store: %@, %@", error, [error userInfo]);
        
        [[NSFileManager defaultManager] removeItemAtURL:self.storeURL error:nil];
        [_persistentStoreCoordinator addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:self.storeURL options:nil error:&error];
    }

    return _persistentStoreCoordinator;
}

- (void)updateMessage:(UAInboxMessage *)message withDictionary:(NSDictionary *)dict {
    message.messageID = [dict objectForKey:@"message_id"];
    message.contentType = [dict objectForKey:@"content_type"];
    message.title = [dict objectForKey:@"title"];
    message.extra = [dict objectForKey:@"extra"];
    message.messageBodyURL = [NSURL URLWithString: [dict objectForKey:@"message_body_url"]];
    message.messageURL = [NSURL URLWithString: [dict objectForKey:@"message_url"]];
    message.unread = [[dict objectForKey:@"unread"] boolValue];
    message.messageSent = [[UAUtils ISODateFormatterUTC] dateFromString:[dict objectForKey:@"message_sent"]];
    message.rawMessageObject = dict;

    NSString *messageExpiration = [dict objectForKey:@"message_expiry"];
    if (messageExpiration) {
        message.messageExpiration = [[UAUtils ISODateFormatterUTC] dateFromString:messageExpiration];
    } else {
        messageExpiration = nil;
    }
}

#pragma mark - Expired Message Deletion

- (void)deleteExpiredMessages {
  [self deleteExpiredMessagesInContext:self.managedObjectContext];
}

- (void)deleteExpiredMessagesInContext:(NSManagedObjectContext *)managedObjectContext {
    NSFetchRequest *request = [[NSFetchRequest alloc] init];
    NSEntityDescription *entity = [NSEntityDescription entityForName:kUAInboxDBEntityName
                                              inManagedObjectContext:managedObjectContext];
    [request setEntity:entity];
    
    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"messageExpiration < %@", [NSDate date]];
    [request setPredicate:predicate];
    
    NSError *countError = nil;
    NSInteger expiredMessageCount = [managedObjectContext countForFetchRequest:request error:&countError];
    
    if (expiredMessageCount == NSNotFound) {
        UA_LERR(@"Error fetching expired message count: %@, %@", countError, [countError userInfo]);
    }
    else if (expiredMessageCount > 0) {
        NSError *error = nil;
        NSArray *resultData = [self.managedObjectContext executeFetchRequest:request error:&error];
        
        for (UAInboxMessageData *messageData in resultData) {
            UA_LDEBUG(@"Deleting expired message: %@", messageData.messageID);
            [self.managedObjectContext deleteObject:messageData];
        }
    }
}

- (void)deleteExpiredMessagesWithCompletion:(void(^)(NSError *saveError))completion {
    [self performBackgroundActionAndSave:^(NSManagedObjectContext *context){
      [self deleteExpiredMessagesInContext:context];
    } completion:completion];
}

- (void)deleteOldDatabaseIfExists {
    NSArray *libraryDirectories = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES);
    NSString *libraryDirectory = [libraryDirectories objectAtIndex:0];
    NSString *dbPath = [libraryDirectory stringByAppendingPathComponent:OLD_DB_NAME];
    
    if ([[NSFileManager defaultManager] fileExistsAtPath:dbPath]) {
        [[NSFileManager defaultManager] removeItemAtPath:dbPath error:nil];
    }
}

#pragma mark - Get Messages

-(UAInboxMessage *)getMessageWithID:(NSString *)messageID context:(NSManagedObjectContext *)context {
  if (!messageID) {
    return nil;
  }
  
  NSFetchRequest *request = [[NSFetchRequest alloc] init];
    NSEntityDescription *entity = [NSEntityDescription entityForName:kUAInboxDBEntityName
                                              inManagedObjectContext:context];
  [request setEntity:entity];
  
  
  NSPredicate *predicate = [NSPredicate predicateWithFormat:@"messageID == %@", messageID];
  [request setPredicate:predicate];
  
  NSError *error = nil;
    NSArray *resultData = [context executeFetchRequest:request
                                                 error:&error];
  
  if (error) {
    UA_LWARN("Error when retrieving message with id %@", messageID);
    return nil;
  }
  
  
    if (!resultData || !resultData.count) {
    return nil;
  }
  
    UAInboxMessage *message = [UAInboxMessage messageWithData:[resultData lastObject]];
    return message;
}

-(UAInboxMessage *)getMessageWithID:(NSString *)messageID {
  return [self getMessageWithID:messageID context:self.managedObjectContext];
}

#pragma mark - Store Management

- (NSURL *)getStoreDirectoryURL {
    NSFileManager *fm = [NSFileManager defaultManager];

    NSURL *libraryDirectoryURL = [[fm URLsForDirectory:NSLibraryDirectory inDomains:NSUserDomainMask] lastObject];
    NSURL *directoryURL = [libraryDirectoryURL URLByAppendingPathComponent: CORE_DATA_DIRECTORY_NAME];

    // Create the store directory if it doesnt exist
    if (![fm fileExistsAtPath:[directoryURL path]]) {
        NSError *error = nil;
        if (![fm createDirectoryAtURL:directoryURL withIntermediateDirectories:YES attributes:nil error:&error]) {
            UA_LERR(@"Error creating inbox directory %@: %@", [directoryURL lastPathComponent], error);
        } else {
            [UAUtils addSkipBackupAttributeToItemAtURL:directoryURL];
        }
    }

    return directoryURL;
}

- (void)dealloc {
  [self cleanUpManagedObjectContexts];
}

@end
