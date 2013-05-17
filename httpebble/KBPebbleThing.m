//
//  KBPebbleThing.m
//  httpebble
//
//  Created by Katharine Berry on 10/05/2013.
//  Copyright (c) 2013 Katharine Berry. All rights reserved.
//

#import "KBPebbleThing.h"
#import "KBPebbleValue.h"
#import <PebbleKit/PebbleKit.h>
#import <CoreData/CoreData.h>
#define HTTP_UUID { 0x91, 0x41, 0xB6, 0x28, 0xBC, 0x89, 0x49, 0x8E, 0xB1, 0x47, 0x04, 0x9F, 0x49, 0xC0, 0x99, 0xAD }

#define HTTP_URL_KEY @(0xFFFF)
#define HTTP_STATUS_KEY @(0xFFFE)
#define HTTP_SUCCESS_KEY_DEPRECATED @(0xFFFD)
#define HTTP_COOKIE_KEY @(0xFFFC)
#define HTTP_CONNECT_KEY @(0xFFFB)

#define HTTP_APP_ID_KEY @(0xFFF2)
#define HTTP_COOKIE_STORE_KEY @(0xFFF0)
#define HTTP_COOKIE_LOAD_KEY @(0xFFF1)
#define HTTP_COOKIE_FSYNC_KEY @(0xFFF3)
#define HTTP_COOKIE_DELETE_KEY @(0xFFF4)

#define HTTP_TIME_KEY @(0xFFF5)
#define HTTP_UTC_OFFSET_KEY @(0xFFF6)
#define HTTP_IS_DST_KEY @(0xFFF7)
#define HTTP_TZ_NAME_KEY @(0xFFF8)

@interface KBPebbleThing () <PBPebbleCentralDelegate> {
    PBWatch *ourWatch; // We actually never really use this.
    id updateHandler;
    NSManagedObjectContext *managedObjectContext; // Because Core Data.
    NSPersistentStoreCoordinator *persistentStoreCoordinator;
    NSManagedObjectModel *managedObjectModel;
}

- (BOOL)handleWatch:(PBWatch*)watch message:(NSDictionary*)message;
- (BOOL)handleWatch:(PBWatch*)watch HTTPRequestFromMessage:(NSDictionary *)message;
- (BOOL)handleWatch:(PBWatch*)watch storeKeyFromMessage:(NSDictionary*)message;
- (BOOL)handleWatch:(PBWatch*)watch getKeyFromMessage:(NSDictionary*)message;
- (BOOL)handleWatch:(PBWatch*)watch saveFromMessage:(NSDictionary*)message;
- (BOOL)handleWatch:(PBWatch *)watch deleteFromMessage:(NSDictionary *)message;
- (BOOL)handleWatch:(PBWatch *)watch timeFromMessage:(NSDictionary *)message;
- (KBPebbleValue*)getStoredValueForApp:(NSNumber*)appID withKey:(NSNumber*)key;
- (void)storeId:(id)value InPebbleValue:(KBPebbleValue*)pv;
- (id)getIdFromPebbleValue:(KBPebbleValue*)pv;

@end

@implementation KBPebbleThing

- (id)init
{
    self = [super init];
    if (self) {
        [[PBPebbleCentral defaultCentral] setDelegate:self];
        [self setOurWatch:[[PBPebbleCentral defaultCentral] lastConnectedWatch]];
        
        // Set up the object model.
        NSURL *modelURL = [[NSBundle mainBundle] URLForResource:@"PebbleModel" withExtension:@"momd"];
        managedObjectModel = [[NSManagedObjectModel alloc] initWithContentsOfURL:modelURL];
        // Set up the persistent store coordinator
        NSURL *storeURL = [[[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] lastObject] URLByAppendingPathComponent:@"pebble-kv.sqlite"];
        persistentStoreCoordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:managedObjectModel];
        NSError *error;
        [persistentStoreCoordinator addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:storeURL options:nil error:&error];
        if(error) {
            NSLog(@"Something went very wrong. Deleting key-value store.");
            NSLog(@"%@", error);
            [[NSFileManager defaultManager] removeItemAtURL:storeURL error:nil];
            error = nil;
            [persistentStoreCoordinator addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:storeURL options:nil error:&error];
            if(error) {
                NSLog(@"%@", error);
                abort();
            }
        }
        
        
        managedObjectContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
        [managedObjectContext setPersistentStoreCoordinator:persistentStoreCoordinator];
    }
    return self;
}

- (void)saveKeyValueData {
    [managedObjectContext save:nil];
}

- (void)setOurWatch:(PBWatch*)watch {
    if(watch == nil) return;
    [watch appMessagesGetIsSupported:^(PBWatch *watch, BOOL isAppMessagesSupported) {
        if(!isAppMessagesSupported) return;
        uint8_t uuid[] = HTTP_UUID;
        [watch appMessagesSetUUID:[NSData dataWithBytes:uuid length:sizeof(uuid)]];
        if(ourWatch && updateHandler)
            [ourWatch appMessagesRemoveUpdateHandler:updateHandler];
        
        updateHandler = [watch appMessagesAddReceiveUpdateHandler:^BOOL(PBWatch *watch, NSDictionary *update) {
            return [self handleWatch:watch message:update];
        }];
        ourWatch = watch;
        NSLog(@"Connected to watch %@", [watch name]);
        [watch appMessagesPushUpdate:@{HTTP_CONNECT_KEY: [NSNumber numberWithUint8:YES]} onSent:^(PBWatch *watch, NSDictionary *update, NSError *error) {
            if(!error) {
                NSLog(@"Pushed post-reconnect update.");
            } else {
                NSLog(@"Error pushing post-reconnect update: %@", error);
            }
        }];
    }];
}

#pragma mark PBPebbleCentral delegate

- (void)pebbleCentral:(PBPebbleCentral *)central watchDidConnect:(PBWatch *)watch isNew:(BOOL)isNew {
    NSLog(@"A watch connected: %@", [watch name]);
    [self setOurWatch:watch];
}

- (void)pebbleCentral:(PBPebbleCentral *)central watchDidDisconnect:(PBWatch *)watch {
    NSLog(@"A watch disconnected.");
    if(watch == ourWatch) {
        NSLog(@"It was ours!");
        [watch closeSession:nil];
        if(updateHandler) {
            [watch appMessagesRemoveUpdateHandler:updateHandler];
            updateHandler = nil;
        }
        [self setOurWatch:nil];
    }
}

#pragma mark Other stuff

void httpErrorResponse(PBWatch* watch, NSNumber* success_key, NSInteger status) {
    NSDictionary *error_response = [NSDictionary
                                    dictionaryWithObjects:@[[NSNumber numberWithUint8:NO], [NSNumber numberWithUint16:status]]
                                    forKeys:@[success_key, HTTP_STATUS_KEY]];
    [watch appMessagesPushUpdate:error_response onSent:^(PBWatch *watch, NSDictionary *update, NSError *error) {
        NSLog(@"Error response failed: %@", error);
    }];
}

- (BOOL)handleWatch:(PBWatch *)watch message:(NSDictionary *)message {
    NSLog(@"Message received.");
    if([message objectForKey:HTTP_URL_KEY]) {
        return [self handleWatch:watch HTTPRequestFromMessage:message];
    }
    if([message objectForKey:HTTP_COOKIE_LOAD_KEY]) {
        return [self handleWatch:watch getKeyFromMessage:message];
    }
    if([message objectForKey:HTTP_COOKIE_STORE_KEY]) {
        return [self handleWatch:watch storeKeyFromMessage:message];
    }
    if([message objectForKey:HTTP_COOKIE_FSYNC_KEY]) {
        return [self handleWatch:watch saveFromMessage:message];
    }
    if([message objectForKey:HTTP_COOKIE_DELETE_KEY]) {
        return [self handleWatch:watch deleteFromMessage:message];
    }
    if([message objectForKey:HTTP_TIME_KEY]) {
        return [self handleWatch:watch timeFromMessage:message];
    }
    return NO;
}

- (BOOL)handleWatch:(PBWatch *)watch HTTPRequestFromMessage:(NSDictionary *)message {
    NSURL* url = [NSURL URLWithString:[message objectForKey:HTTP_URL_KEY]];
    NSNumber* cookie = [message objectForKey:HTTP_COOKIE_KEY];
    // Now we have an app ID, too.
    NSNumber* app_id = [message objectForKey:HTTP_APP_ID_KEY];
    NSNumber* success_key = HTTP_URL_KEY;
    // We're using the deprecated protocol if this is unset.
    if(!app_id) {
        app_id = @(0);
        success_key = HTTP_SUCCESS_KEY_DEPRECATED;
        NSLog(@"Using deprecated protocol.");
    }
    
    NSLog(@"Asked to request the contents of %@", url);
    NSMutableDictionary *request_dict = [[NSMutableDictionary alloc] initWithCapacity:[message count]];
    for (NSNumber* key in message) {
        if([key isEqualToNumber:HTTP_URL_KEY] || [key isEqualToNumber:HTTP_COOKIE_KEY]) {
            continue;
        }
        [request_dict setValue:[message objectForKey:key] forKey:[key stringValue]];
    }
    [request_dict removeObjectsForKeys:@[HTTP_URL_KEY, HTTP_COOKIE_KEY]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setHTTPMethod:@"POST"];
    [request setValue:[watch serialNumber] forHTTPHeaderField:@"X-Pebble-ID"];
    NSLog(@"X-Pebble-ID: %@", [request valueForHTTPHeaderField:@"X-Pebble-ID"]);
    [request setHTTPBody:[NSJSONSerialization dataWithJSONObject:request_dict options:0 error:nil]];
    NSLog(@"Made request with data: %@", request_dict);
    [NSURLConnection sendAsynchronousRequest:request
                                       queue:[NSOperationQueue currentQueue]
                           completionHandler:^(NSURLResponse *response, NSData *data, NSError *error) {
                               NSLog(@"Got HTTP response.");
                               NSInteger status_code = [(NSHTTPURLResponse*)response statusCode];
                               if(error) {
                                   NSLog(@"Something went wrong: %@", error);
                                   httpErrorResponse(watch, success_key, status_code);
                                   return;
                               }
                               NSError *json_error = nil;
                               NSDictionary *json_response = [NSJSONSerialization JSONObjectWithData:data options:0 error:&json_error];
                               if(error) {
                                   NSLog(@"Invalid JSON: %@", json_error);
                                   httpErrorResponse(watch, success_key, 500);
                                   return;
                               }
                               NSMutableDictionary *response_dict = [[NSMutableDictionary alloc] initWithCapacity:[json_response count]];
                               NSLog(@"Parsing received dictionary: %@", json_response);
                               for(NSString* key in json_response) {
                                   NSNumber *k = [NSNumber numberWithInteger:[key integerValue]];
                                   id value = [json_response objectForKey:key];
                                   if([value isKindOfClass:[NSArray class]]) {
                                       NSArray* array_value = (NSArray*)value;
                                       if([array_value count] != 2 ||
                                          ![[array_value objectAtIndex:0] isKindOfClass:[NSString class]] ||
                                          ![[array_value objectAtIndex:1] isKindOfClass:[NSNumber class]]) {
                                           NSLog(@"Illegal size specification: %@", array_value);
                                           httpErrorResponse(watch, success_key, 500);
                                           return;
                                       }
                                       NSString *size_specification = [array_value objectAtIndex:0];
                                       NSInteger number = [[array_value objectAtIndex:1] integerValue];
                                       NSNumber *pebble_value;
                                       if([size_specification isEqualToString:@"b"]) {
                                           pebble_value = [NSNumber numberWithInt8:number];
                                       } else if([size_specification isEqualToString:@"B"]) {
                                           pebble_value = [NSNumber numberWithUint8:number];
                                       } else if([size_specification isEqualToString:@"s"]) {
                                           pebble_value = [NSNumber numberWithInt16:number];
                                       } else if([size_specification isEqualToString:@"S"]) {
                                           pebble_value = [NSNumber numberWithUint16:number];
                                       } else if([size_specification isEqualToString:@"i"]) {
                                           pebble_value = [NSNumber numberWithInt32:number];
                                       } else if([size_specification isEqualToString:@"I"]) {
                                           pebble_value = [NSNumber numberWithUint32:number];
                                       } else {
                                           NSLog(@"Illegal size string: %@", size_specification);
                                           httpErrorResponse(watch, success_key, 500);
                                           return;
                                       }
                                       [response_dict setObject:pebble_value forKey:k];
                                   } else if([value isKindOfClass:[NSString class]]) {
                                       [response_dict setObject:value forKey:k];
                                   } else if([value isKindOfClass:[NSNumber class]]) {
                                       [response_dict setObject:[NSNumber numberWithInt32:[value integerValue]] forKey:k];
                                   }
                               }
                               [response_dict setObject:[NSNumber numberWithUint8:YES] forKey:success_key];
                               [response_dict setObject:[NSNumber numberWithUint16:status_code] forKey:HTTP_STATUS_KEY];
                               [response_dict setObject:app_id forKey:HTTP_APP_ID_KEY];
                               [response_dict setObject:cookie forKey:HTTP_COOKIE_KEY];
                               NSLog(@"Pushing dictionary to watch: %@", response_dict);
                               [watch appMessagesPushUpdate:response_dict onSent:^(PBWatch *watch, NSDictionary *update, NSError *error) {
                                   if(error) {
                                       NSLog(@"Response send failed: %@", error);
                                   }
                               }];
                           }
     ];
    return YES;
}

- (KBPebbleValue*)getStoredValueForApp:(NSNumber *)appID withKey:(NSNumber *)key {
    NSFetchRequest *request = [[NSFetchRequest alloc] init];
    [request setEntity:[NSEntityDescription entityForName:@"KBPebbleValue" inManagedObjectContext:managedObjectContext]];
    [request setPredicate:[NSPredicate predicateWithFormat:@"app_id = %@ AND key = %@", appID, key, nil]];
    NSError* error;
    KBPebbleValue *v = [[managedObjectContext executeFetchRequest:request error:&error] lastObject];
    if(error) {
        return nil;
    }
    return v;
}

- (void)storeId:(id)value InPebbleValue:(KBPebbleValue*)pv {
    if([value isKindOfClass:[NSNumber class]]) {
        NSNumber* num = value;
        uint8_t* data = alloca([num width] + 1);
        data[0] = [num isSigned];
        [num getValue:&data[1]];
        pv.value = [NSData dataWithBytes:data length:[num width]+1];
        pv.kind = KB_PEBBLE_VALUE_NUMBER;
    } else if([value isKindOfClass:[NSString class]]) {
        NSString* str = value;
        pv.value = [str dataUsingEncoding:NSUTF8StringEncoding];
        pv.kind = KB_PEBBLE_VALUE_STRING;
    } else if([value isKindOfClass:[NSData class]]) {
        pv.value = value;
        pv.kind = KB_PEBBLE_VALUE_DATA;
    }
}

- (id)getIdFromPebbleValue:(KBPebbleValue*)pv {
    if([pv.kind isEqualToNumber:KB_PEBBLE_VALUE_DATA]) {
        return pv.value;
    } else if([pv.kind isEqualToNumber:KB_PEBBLE_VALUE_STRING]) {
        return [[NSString alloc] initWithData:pv.value encoding:NSUTF8StringEncoding];
    } else if([pv.kind isEqualToNumber:KB_PEBBLE_VALUE_NUMBER]) {
        // Well this is tedious.
        const uint8_t *bytes = pv.value.bytes;
        BOOL is_signed = (BOOL)bytes[0];
        if(is_signed) {
            switch (pv.value.length) {
                case 2:
                    return [NSNumber numberWithInt8:bytes[1]];
                case 3:
                    return [NSNumber numberWithInt16:(bytes[2]) << 8 | (bytes[1])];
                case 5:
                    return [NSNumber numberWithInt32:(bytes[4] << 24) | (bytes[3] << 16) | (bytes[2]) << 8 | (bytes[1])];
            }
        } else {
            switch (pv.value.length) {
                case 2:
                    return [NSNumber numberWithUint8:bytes[1]];
                case 3:
                    return [NSNumber numberWithUint16:(bytes[2]) << 8 | (bytes[1])];
                case 5:
                    return [NSNumber numberWithUint32:(bytes[4] << 24) | (bytes[3] << 16) | (bytes[2]) << 8 | (bytes[1])];
            }
        }
    }
    return nil;
}

- (BOOL)handleWatch:(PBWatch *)watch storeKeyFromMessage:(NSDictionary *)message {
    KBPebbleValue *v;
    NSNumber *appID = message[HTTP_APP_ID_KEY];
    NSNumber *cookie = message[HTTP_COOKIE_STORE_KEY];
    NSMutableDictionary *dict = [message mutableCopy];
    [dict removeObjectForKey:HTTP_APP_ID_KEY];
    [dict removeObjectForKey:HTTP_COOKIE_STORE_KEY];
    for(NSNumber *key in dict) {
        v = [self getStoredValueForApp:appID withKey:key];
        if(!v) {
            v = (KBPebbleValue*)[NSEntityDescription insertNewObjectForEntityForName:@"KBPebbleValue" inManagedObjectContext:managedObjectContext];
            v.app_id = appID;
            v.key = key;
        }
        [self storeId:message[key] InPebbleValue:v];
        NSLog(@"Set %@ = %@", key, v.value);
    }
    // Confirm success
    [watch appMessagesPushUpdate:@{HTTP_COOKIE_STORE_KEY: cookie, HTTP_APP_ID_KEY: appID} onSent:nil];
    [self saveKeyValueData];
    return YES;
}

- (BOOL)handleWatch:(PBWatch *)watch getKeyFromMessage:(NSDictionary *)message {
    NSNumber *appID = message[HTTP_APP_ID_KEY];
    NSNumber *cookie = message[HTTP_COOKIE_LOAD_KEY];
    NSMutableDictionary *response = [[NSMutableDictionary alloc] init];
    for(NSNumber *key in message) {
        if([key isEqualToNumber:HTTP_APP_ID_KEY] || [key isEqualToNumber:HTTP_COOKIE_LOAD_KEY]) {
            continue;
        }
        KBPebbleValue *v = [self getStoredValueForApp:appID withKey:key];
        if(v) {
            response[key] = [self getIdFromPebbleValue:v];
            NSLog(@"Got %@ = %@", key, response[key]);
        } else {
            NSLog(@"Failed to find a value for %@.", key);
        }
    }
    response[HTTP_COOKIE_LOAD_KEY] = cookie;
    response[HTTP_APP_ID_KEY] = appID;
    [watch appMessagesPushUpdate:response onSent:nil];
    return YES;
}

- (BOOL)handleWatch:(PBWatch *)watch saveFromMessage:(NSDictionary *)message {
    NSError *error;
    [managedObjectContext save:&error];
    BOOL success = YES;
    if(error) {
        NSLog(@"Save failed: %@", error);
        success = NO;
    }
    [watch appMessagesPushUpdate:@{HTTP_COOKIE_FSYNC_KEY: [NSNumber numberWithUint8:success], HTTP_APP_ID_KEY: message[HTTP_APP_ID_KEY]} onSent:nil];
    return YES;
}

- (BOOL)handleWatch:(PBWatch *)watch deleteFromMessage:(NSDictionary *)message {
    NSNumber *appID = message[HTTP_APP_ID_KEY];
    NSNumber *cookie = message[HTTP_COOKIE_DELETE_KEY];
    for(NSNumber *key in message) {
        if([key isEqualToNumber:HTTP_APP_ID_KEY] || [key isEqualToNumber:HTTP_COOKIE_DELETE_KEY]) {
            continue;
        }
        KBPebbleValue *v = [self getStoredValueForApp:appID withKey:key];
        if(v) {
            NSLog(@"Deleting object %@ for %@", key, appID);
            [managedObjectContext deleteObject:v];
        }
    }
    [watch appMessagesPushUpdate:@{HTTP_COOKIE_DELETE_KEY: cookie, HTTP_APP_ID_KEY: appID} onSent:nil];
    [self saveKeyValueData];
    return YES;
}

- (BOOL)handleWatch:(PBWatch *)watch timeFromMessage:(NSDictionary *)message {
    NSMutableDictionary *response = [message mutableCopy];
    NSTimeZone* tz = [NSTimeZone systemTimeZone];
    response[HTTP_UTC_OFFSET_KEY] = [NSNumber numberWithInt32:[tz secondsFromGMT]];
    response[HTTP_IS_DST_KEY] = [NSNumber numberWithUint8:[tz isDaylightSavingTime]];
    response[HTTP_TZ_NAME_KEY] = [tz name];
    response[HTTP_TIME_KEY] = [NSNumber numberWithUint32:time(nil)];
    NSLog(@"Sending tz data: %@", response);
    [watch appMessagesPushUpdate:response onSent:nil];
    return YES;
}

@end
