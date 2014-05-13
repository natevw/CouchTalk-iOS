//
//  CBAppDelegate.m
//  CouchTalk
//
//  Created by Chris Anderson on 3/26/14.
//  Copyright (c) 2014 Chris Anderson. All rights reserved.
//

#import "CBAppDelegate.h"
#import <CouchbaseLite/CouchbaseLite.h>
#import <CouchbaseLiteListener/CBLListener.h>

//#import <CocoaHTTPServer/HTTPServer.h>    // pod is old broken version, and causes linker conflicts with CBL…
#import "CBMasterViewController.h"
#import "CouchTalkRedirector.h"


NSString* const HOST_URL = @"http://sync.couchbasecloud.com/couchtalk";      // TODO: move into app's plist or something?
NSString* const ITEM_TYPE = @"com.couchbase.couchtalk.message-item";

@implementation CBAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    // Override point for customization after application launch.
    if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad) {
        UISplitViewController *splitViewController = (UISplitViewController *)self.window.rootViewController;
        UINavigationController *navigationController = [splitViewController.viewControllers lastObject];
        splitViewController.delegate = (id)navigationController.topViewController;
        
        // HACK: should probably use an IBOutlet or something instead…
        navigationController = [splitViewController.viewControllers firstObject];
        self.mainController = (id)navigationController.topViewController;
    } else {
        self.mainController = (id)(((UINavigationController*)self.window.rootViewController).visibleViewController);
    }
    
    [self setupCouchbaseListener];
    
    return YES;
}

- (CBLReplication*) startReplicationsWithDatabase:(CBLDatabase *)database {
    NSURL* centralDatabase = [NSURL URLWithString:HOST_URL];
    CBLReplication* pushReplication = [database createPushReplication:centralDatabase];
    pushReplication.continuous = YES;
    [pushReplication start];
    
    CBLReplication* pullReplication = [database createPullReplication:centralDatabase];
    pullReplication.continuous = YES;
    // instead of starting, we let caller start once it needs at least one channel
    return pullReplication;
}

- (void) setupCouchbaseListener {
    CBLManager* manager = [CBLManager sharedInstance];
    NSError *error;
    CBLDatabase* database = [manager databaseNamed:@"couchtalk" error:&error];
    
    CBLView* detailViewView = [database viewNamed:@"snapshotsByRoom"];
    [detailViewView setMapBlock: MAPBLOCK({
        if (
            [doc[@"type"] isEqualToString:ITEM_TYPE] &&
            [doc[@"snapshotNumber"] isEqual:@"join"]
        ) emit(doc[@"room"], nil);
    }) version:@"1.0"];
    
    CBLView* roomSnapsView = [database viewNamed:@"app/initialSnapshotsByRoomAndTimestamp"];
    [roomSnapsView setMapBlock: MAPBLOCK({
        if (
            [doc[@"type"] isEqualToString:ITEM_TYPE] &&
            ([doc[@"snapshotNumber"] isEqual:@"join"] || [doc[@"snapshotNumber"] isEqual:@(0)])
        ) emit(@[
            doc[@"room"],
            doc[@"timestamp"]
        ], doc[@"message"]);
    }) version:@"1.0"];
    
    CBLView* messageAudioView = [database viewNamed:@"app/audioItemsByMessage"];
    [messageAudioView setMapBlock: MAPBLOCK({
        if (
            [doc[@"type"] isEqualToString:ITEM_TYPE] &&
            !doc[@"snapshotNumber"]
        ) emit(doc[@"message"], nil);
    }) version:@"1.0"];
    
    CBLReplication* pullReplication = [self startReplicationsWithDatabase:database];
    NSMutableSet* channelsUsed = [NSMutableSet set];
    NSMutableArray* roomItems = [NSMutableArray array];
    void (^subscribeToRoom)(NSString*) = ^(NSString* room) {
        NSString* channel = [NSString stringWithFormat:@"room-%@", room];
        if (channel && ![channelsUsed containsObject:channel]) {
          [channelsUsed addObject:channel];
          pullReplication.channels = [channelsUsed allObjects];
          if (!pullReplication.running) [pullReplication start];
          NSLog(@"Now syncing with %@", pullReplication.channels);
          
          CBLQuery* query = [roomSnapsView createQuery];
          query.startKey = @[ room ];
          query.endKey = @[ room, @{} ];
          [roomItems addObject:@{
              @"room": room,
              @"query": query,
              @"added": [NSDate date]
          }];
          self.mainController.objects = roomItems;
        }
    };
    [[NSNotificationCenter defaultCenter] addObserverForName:kCBLDatabaseChangeNotification object:database queue:nil usingBlock:^(NSNotification *note) {
      for (CBLDatabaseChange* change in note.userInfo[@"changes"]) {
        if (change.source) continue;    // handy! this means it was synced from remote (not that we'd get items from unsubscribed channels anyway though…)
        CBLDocument* doc = [database existingDocumentWithID:change.documentID];
        /* NOTE: the following code expects this Sync Gateway callback to be installed
        function(doc) {
          if (doc.room) {
            channel('room-'+doc.room);
          }
        }
        */
        if ([doc[@"type"] isEqualToString:ITEM_TYPE]) subscribeToRoom(doc[@"room"]);
      }
    }];
    subscribeToRoom(@"howto");
    
    [database setFilterNamed: @"app/roomItems" asBlock: FILTERBLOCK({
        // WORKAROUND: https://github.com/couchbase/couchbase-lite-ios/issues/321
        /*
        function expando(prefix, string) {
          var params = {};
          params[prefix+'LEN'] = string.length;
          Array.prototype.forEach.call(string, function (s,i) {
            params[''+prefix+i] = s.charCodeAt(0);
          });
          return params;
        }
        var o = expando('room', "😄 Happy π day!");
        Object.keys(o).map(function (k) { return [k,o[k]].join('='); }).join('&');
        */
        NSUInteger roomLen = [params[@"roomLEN"] unsignedIntegerValue];
        if (roomLen > 64) return NO;            // sanity check
        unichar roomBuffer[roomLen];            // conveniently, JavaScript also pre-dates Unicode 2.0
        for (NSUInteger i = 0, len = roomLen; i < len; ++i) {
            NSString* key = ([NSString stringWithFormat:@"room%lu", (unsigned long)i]);
            roomBuffer[i] = [params[key] unsignedShortValue];
        }
        NSString* roomName = [[NSString alloc] initWithCharactersNoCopy:roomBuffer length:roomLen freeWhenDone:NO];
        
        //NSString* roomName = params[@"room"];
        return (
            [revision[@"type"] isEqualToString:ITEM_TYPE] &&
            [revision[@"room"] isEqualToString:roomName]
        );
    })];
    
    CBLListener* _listener = [[CBLListener alloc] initWithManager: manager port: 59840];
    BOOL ok = [_listener start: &error];
    if (ok) {
        UInt16 actualPort = _listener.port;  // the actual TCP port it's listening on
        NSLog(@"listening on %d", actualPort);
    } else {
        NSLog(@"Couchbase Lite listener not started");
    }
    
    CouchTalkRedirector* redirector = [[CouchTalkRedirector alloc] init];
    [redirector setType:@"_http._tcp."];
    [redirector setPort:8080];            // pros: easy to remember/type, cons: what if already in use?
    ok = [redirector start:&error];
    if (!ok) {
        NSLog(@"Couldn't start redirect helper: %@", error);
    } else {
        NSLog(@"Redirector listening on %u", redirector.listeningPort);
    }
    CFRetain((__bridge CFTypeRef)redirector);       // TODO/HACK: need a better way to keep this around
    
    // TODO: add Reachability monitoring?
    NSDictionary* wifi = [CouchTalkRedirector networkInfo];
    if (wifi[@"IPv4"]) {
        self.wifi = @{
            @"SSID": wifi[@"SSID"],
            @"URL": [NSURL URLWithString:[NSString stringWithFormat:@"http://%@:%u", wifi[@"IPv4"], redirector.listeningPort]],
            @"IPv4": wifi[@"IPv4"],
            @"port": @(redirector.listeningPort)
        };
    } else {
        self.wifi = nil;
    }
}

- (void)applicationWillResignActive:(UIApplication *)application
{
NSLog(@"applicationWillResignActive");
    // Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
    // Use this method to pause ongoing tasks, disable timers, and throttle down OpenGL ES frame rates. Games should use this method to pause the game.
}

- (void)applicationDidEnterBackground:(UIApplication *)application
{
NSLog(@"applicationDidEnterBackground");
    // Use this method to release shared resources, save user data, invalidate timers, and store enough application state information to restore your application to its current state in case it is terminated later. 
    // If your application supports background execution, this method is called instead of applicationWillTerminate: when the user quits.
}

- (void)applicationWillEnterForeground:(UIApplication *)application
{
    // Called as part of the transition from the background to the inactive state; here you can undo many of the changes made on entering the background.
}

- (void)applicationDidBecomeActive:(UIApplication *)application
{
    // Restart any tasks that were paused (or not yet started) while the application was inactive. If the application was previously in the background, optionally refresh the user interface.
}

- (void)applicationWillTerminate:(UIApplication *)application
{
NSLog(@"applicationWillTerminate");
    // Called when the application is about to terminate. Save data if appropriate. See also applicationDidEnterBackground:.
}

@end


@implementation UIApplication (CBAppDelegate)

+ (CBAppDelegate *)cb_sharedDelegate {
    return [UIApplication sharedApplication].delegate;
}

@end
