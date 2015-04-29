//
//  KBLaunchCtl.m
//  Keybase
//
//  Created by Gabriel on 3/12/15.
//  Copyright (c) 2015 Gabriel Handford. All rights reserved.
//

#import "KBLaunchCtl.h"
#import "KBEnvironment.h"

@interface KBLaunchCtl ()
@property KBEnvironment *environment;
@end

@implementation KBLaunchCtl

- (instancetype)initWithEnvironment:(KBEnvironment *)environment {
  if ((self = [super init])) {
    _environment = environment;
  }
  return self;
}

+ (NSDictionary *)launchdPlistDictionaryForEnvironment:(KBEnvironment *)environment {
  NSMutableArray *args = [NSMutableArray array];
  [args addObject:@"/Applications/Keybase.app/Contents/MacOS/keybased"];
  [args addObjectsFromArray:@[@"-H", environment.home]];

  if (environment.host) {
    [args addObjectsFromArray:@[@"-s", environment.host]];
  }

  if (environment.isDebugEnabled) {
    [args addObject:@"-d"];
  }

  // Need to create logging dir here because otherwise it will be created as root by launchctl
  NSString *logDir = [@"~/Library/Logs/Keybase" stringByExpandingTildeInPath];
  [NSFileManager.defaultManager createDirectoryAtPath:logDir withIntermediateDirectories:YES attributes:nil error:nil];

  NSString *stdOutPath = NSStringWithFormat(@"%@/%@.log", logDir, environment.launchdLabel);
  NSString *stdErrPath = NSStringWithFormat(@"%@/%@.err", logDir, environment.launchdLabel);

  NSDictionary *plist = @{
                 @"Label": environment.launchdLabel,
                 @"ProgramArguments": args,
                 @"StandardOutPath": stdOutPath,
                 @"StandardErrorPath": stdErrPath,
                 @"KeepAlive": @YES
                 };
  return plist;
}

+ (NSString *)launchdPlistForEnvironment:(KBEnvironment *)environment error:(NSError **)error {
  NSData *data = [NSPropertyListSerialization dataWithPropertyList:[self launchdPlistDictionaryForEnvironment:environment] format:NSPropertyListXMLFormat_v1_0 options:0 error:error];
  return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

- (void)reload:(KBLaunchStatus)completion {
  [self unload:NO completion:^(NSError *unloadError, NSString *unloadOutput) {
    [self wait:NO attempt:1 completion:^(NSError *error, NSInteger pid) {
      [self load:YES completion:^(NSError *loadError, NSString *loadOutput) {
        [self wait:YES attempt:1 completion:^(NSError *error, NSInteger pid) {
          completion(loadError, pid);
        }];
      }];
    }];
  }];
}

- (NSString *)plist {
  NSString *launchAgentDir = [[NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) firstObject] stringByAppendingPathComponent:@"LaunchAgents"];
  return [launchAgentDir stringByAppendingPathComponent:NSStringWithFormat(@"%@.plist", _environment.launchdLabel)];
}

- (void)load:(BOOL)force completion:(KBLaunchExecution)completion {
  NSMutableArray *args = [NSMutableArray array];
  [args addObject:@"load"];
  if (force) [args addObject:@"-w"];
  [args addObject:self.plist];
  [self execute:@"/bin/launchctl" args:args completion:completion];
}

- (void)unload:(BOOL)disable completion:(KBLaunchExecution)completion {
  NSMutableArray *args = [NSMutableArray array];
  [args addObject:@"unload"];
  if (disable) [args addObject:@"-w"];
  [args addObject:self.plist];
  [self execute:@"/bin/launchctl" args:args completion:completion];
}

- (void)status:(KBLaunchStatus)completion {
  NSString *label = _environment.launchdLabel;
  [self execute:@"/bin/launchctl" args:@[@"list"] completion:^(NSError *error, NSString *output) {
    if (error) {
      completion(error, -1);
      return;
    }
    for (NSString *line in [output componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
      // TODO better parsing
      if ([line containsString:label]) {
        NSInteger pid = [[[line componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]] firstObject] integerValue];
        completion(nil, pid);
        return;
      }
    }
    completion(nil, -1);
  }];
}

- (void)wait:(BOOL)load attempt:(NSInteger)attempt completion:(KBLaunchStatus)completion {
  [self status:^(NSError *error, NSInteger pid) {
    if (load && pid != 0) {
      DDLogDebug(@"Pid: %@", @(pid));
      completion(nil, pid);
    } else if (!load && pid == 0) {
      completion(nil, pid);
    } else {
      if ((attempt + 1) >= 4) {
        completion(KBMakeError(-1, @"launchctl wait timeout"), 0);
      } else {
        DDLogDebug(@"Watiting for %@ (%@)", load ? @"load" : @"unload", @(attempt));
        [self wait:load attempt:attempt+1 completion:completion];
      }
    }
  }];
}

- (void)execute:(NSString *)command args:(NSArray *)args completion:(void (^)(NSError *error, NSString *output))completion {
  NSTask *task = [[NSTask alloc] init];
  task.launchPath = command;
  task.arguments = args;
  NSPipe *outpipe = [NSPipe pipe];
  [task setStandardOutput:outpipe];
  task.terminationHandler = ^(NSTask *t) {
    DDLogDebug(@"Task %@ exited with status: %@", t, @(t.terminationStatus));
    NSFileHandle *read = [outpipe fileHandleForReading];
    NSData *data = [read readDataToEndOfFile];
    NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    dispatch_async(dispatch_get_main_queue(), ^{
      // TODO Check termination status and complete with error if > 0
      completion(nil, output);
    });
  };
  [task launch];
}

- (void)installLaunchAgent:(KBCompletionBlock)completion {
  // Install launch agent (if not installed)
  NSString *plistDest = self.plist;
  if (!plistDest) {
    NSError *error = KBMakeErrorWithRecovery(-1, @"Install Error", @"No launch agent destination.", nil);
    completion(error);
    return;
  }

  //
  // TODO
  // Only install if not exists or upgrade. We are currently always installing/updating the plist.
  //
  //if (![NSFileManager.defaultManager fileExistsAtPath:launchAgentPlistDest]) {
  NSError *error = nil;

  // Remove if exists
  if ([NSFileManager.defaultManager fileExistsAtPath:plistDest]) {
    if (![NSFileManager.defaultManager removeItemAtPath:plistDest error:&error]) {
      if (!error) error = KBMakeErrorWithRecovery(-1, @"Install Error", @"Unable to remove existing luanch agent plist for upgrade.", nil);
      completion(error);
      return;
    }
  }

  NSDictionary *plistDict = [self.class launchdPlistDictionaryForEnvironment:_environment];
  NSData *data = [NSPropertyListSerialization dataWithPropertyList:plistDict format:NSPropertyListXMLFormat_v1_0 options:0 error:&error];
  if (!data) {
    if (!error) error = KBMakeErrorWithRecovery(-1, @"Install Error", @"Unable to create plist data.", nil);
    completion(error);
    return;
  }

  if (![data writeToFile:plistDest atomically:YES]) {
    if (!error) error = KBMakeErrorWithRecovery(-1, @"Install Error", @"Unable to create launch agent plist.", nil);
    completion(error);
    return;
  }

  // We installed the launch agent plist
  DDLogDebug(@"Installed launch agent plist");

  [self reload:^(NSError *error, NSInteger pid) {
    completion(error);
  }];
}

//- (void)checkLaunch:(void (^)(NSError *error))completion {
//  launch_data_t config = launch_data_alloc(LAUNCH_DATA_DICTIONARY);
//
//  launch_data_t val;
//  val = launch_data_new_string("keybase.keybased");
//  launch_data_dict_insert(config, val, LAUNCH_JOBKEY_LABEL);
//  val = launch_data_new_string("/Applications/Keybase.app/Contents/MacOS/keybased");
//  launch_data_dict_insert(config, val, LAUNCH_JOBKEY_PROGRAM);
//  val = launch_data_new_bool(YES);
//  launch_data_dict_insert(config, val, LAUNCH_JOBKEY_KEEPALIVE);
//
//  launch_data_t msg = launch_data_alloc(LAUNCH_DATA_DICTIONARY);
//  launch_data_dict_insert(msg, config, LAUNCH_KEY_SUBMITJOB);
//
//  launch_data_t response = launch_msg(msg);
//  if (!response) {
//    NSError *error = KBMakeErrorWithRecovery(-1, @"Launchd Error", @"Unable to launch keybased agent.", nil);
//    completion(error);
//  } else if (response && launch_data_get_type(response) == LAUNCH_DATA_ERRNO) {
//    //strerror(launch_data_get_errno(response))
//    //NSError *error = KBMakeErrorWithRecovery(-1, @"Launchd Error", @"Unable to launch keybased agent (LAUNCH_DATA_ERRNO).", nil);
//    //completion(error);
//    completion(nil);
//  } else {
//    completion(nil);
//  }
//}

@end
