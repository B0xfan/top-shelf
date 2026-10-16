// Top Shelf now-playing helper. Loaded by /usr/bin/perl (an Apple platform binary MediaRemote still serves on macOS 15.4+).
// Technique from ungive/mediaremote-adapter (BSD-3); code written fresh.
#import <Foundation/Foundation.h>
#include <dlfcn.h>

typedef void (*GetInfoFn)(dispatch_queue_t, void (^)(NSDictionary *));
typedef void (*GetPlayingFn)(dispatch_queue_t, void (^)(BOOL));
typedef void (*GetClientFn)(dispatch_queue_t, void (^)(id));
typedef NSString *(*ClientBundleFn)(id);
typedef void (*RegisterFn)(dispatch_queue_t);
typedef BOOL (*SendFn)(int, NSDictionary *);

static void *mr(const char *name) {
    static void *h; if (!h) h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    return h ? dlsym(h, name) : NULL;
}

static void readCommands(void);
// Commands wait for the first answer: a "play" sent before the current player is known makes macOS open Apple Music.
// A 3-second fallback still starts the reader, so the helper always notices when Top Shelf quits.
static void startCommandsOnce(void) { static dispatch_once_t once; dispatch_once(&once, ^{ readCommands(); }); }

static void emit(void) {
    dispatch_queue_t q = dispatch_get_main_queue();
    ((GetClientFn)mr("MRMediaRemoteGetNowPlayingClient"))(q, ^(id client) {
        NSString *bundle = client ? ((ClientBundleFn)mr("MRNowPlayingClientGetBundleIdentifier"))(client) : nil;
        ((GetInfoFn)mr("MRMediaRemoteGetNowPlayingInfo"))(q, ^(NSDictionary *info) {
            ((GetPlayingFn)mr("MRMediaRemoteGetNowPlayingApplicationIsPlaying"))(q, ^(BOOL playing) {
                NSMutableDictionary *o = [NSMutableDictionary dictionary];
                o[@"playing"] = @(playing);
                if (bundle) o[@"bundle"] = bundle;
                NSDictionary *keys = @{@"title": @"kMRMediaRemoteNowPlayingInfoTitle", @"artist": @"kMRMediaRemoteNowPlayingInfoArtist",
                                       @"album": @"kMRMediaRemoteNowPlayingInfoAlbum", @"duration": @"kMRMediaRemoteNowPlayingInfoDuration",
                                       @"elapsed": @"kMRMediaRemoteNowPlayingInfoElapsedTime"};
                for (NSString *k in keys) { id v = info[keys[k]]; if ([v isKindOfClass:NSString.class] || [v isKindOfClass:NSNumber.class]) o[k] = v; }
                NSData *art = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
                if ([art isKindOfClass:NSData.class] && art.length < 2000000) o[@"art"] = [art base64EncodedStringWithOptions:0];
                NSData *json = [NSJSONSerialization dataWithJSONObject:o options:0 error:nil];
                if (json) { fwrite(json.bytes, 1, json.length, stdout); fputc('\n', stdout); fflush(stdout); }
                startCommandsOnce();
            });
        });
    });
}

// Streams one JSON line per change. Reads command numbers, one per line, from stdin
// (0 play, 1 pause, 2 toggle, 4 next, 5 previous); exits when stdin closes, so it never outlives Top Shelf.
void ts_stream(void) {
    const char *needed[] = {"MRMediaRemoteGetNowPlayingInfo", "MRMediaRemoteGetNowPlayingApplicationIsPlaying", "MRMediaRemoteGetNowPlayingClient",
                            "MRNowPlayingClientGetBundleIdentifier", "MRMediaRemoteRegisterForNowPlayingNotifications", "MRMediaRemoteSendCommand"};
    for (int i = 0; i < 6; i++) if (!mr(needed[i])) { printf("{\"error\":\"missing %s\"}\n", needed[i]); fflush(stdout); exit(3); }
    ((RegisterFn)mr("MRMediaRemoteRegisterForNowPlayingNotifications"))(dispatch_get_main_queue());
    for (NSString *n in @[@"kMRMediaRemoteNowPlayingInfoDidChangeNotification", @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                          @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification"])
        [NSNotificationCenter.defaultCenter addObserverForName:n object:nil queue:nil usingBlock:^(NSNotification *note) { emit(); }];
    emit();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ startCommandsOnce(); });
    CFRunLoopRun();
}

static void readCommands(void) {
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        char line[32];
        while (fgets(line, sizeof line, stdin)) {
            int c = atoi(line);
            if (c < 0 || c > 5) continue;
            dispatch_async(dispatch_get_main_queue(), ^{ ((SendFn)mr("MRMediaRemoteSendCommand"))(c, nil); });
        }
        exit(0);
    });
}
