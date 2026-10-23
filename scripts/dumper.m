// dumper.m — 抖音精选缓存导出插件（TrollStore 注入用）
// 用途：App 每次切到前台，把沙盒内 >=2MB 或视频类扩展名的文件拷贝到
//       /var/mobile/Documents/DouyinCacheDump，日志走 os_log（Mac 控制台 App 可看）
// 环境：iOS 16 + TrollStore；配合砸壳 IPA + insert_dylib 注入
// 注意：注入会改变 App 二进制，有登录风控风险；加密缓存只能原样倒出。

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <os/log.h>
#import <stdarg.h>

static NSString *const kDumpDir = @"/var/mobile/Documents/DouyinCacheDump";
static const unsigned long long kMinSize = 2ULL * 1024 * 1024; // 2MB
static BOOL gDone = NO;

static void DLog(NSString *msg) {
    os_log(OS_LOG_DEFAULT, "[dumper] %{public}s", msg.UTF8String);
}

static BOOL isVideoLike(NSString *path, NSNumber *size) {
    static NSSet *exts = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        exts = [NSSet setWithObjects:@"mp4", @"mov", @"m4v", @"m4s", @"ts",
                @"m3u8", @"mpd", @"aac", @"cache", @"tmp", @"dat", nil];
    });
    NSString *ext = path.pathExtension.lowercaseString;
    if (ext.length && [exts containsObject:ext]) return YES;
    return size && size.unsignedLongLongValue >= kMinSize;
}

static void DumpOnce(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSError *err = nil;
    [fm createDirectoryAtPath:kDumpDir withIntermediateDirectories:YES attributes:nil error:&err];

    NSMutableArray<NSString *> *targets = [NSMutableArray array];

    // 1) App 沙盒递归
    NSDirectoryEnumerator<NSURL *> *en =
        [fm enumeratorAtURL:[NSURL fileURLWithPath:NSHomeDirectory()]
   includingPropertiesForKeys:@[NSURLFileSizeKey, NSURLIsDirectoryKey]
                      options:NSDirectoryEnumerationSkipsHiddenFiles
                 errorHandler:^BOOL(NSURL *u, NSError *e) { return YES; }];
    for (NSURL *u in en) {
        NSNumber *isDir = nil, *size = nil;
        [u getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:nil];
        if (isDir.boolValue) continue;
        [u getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
        if (isVideoLike(u.path, size)) [targets addObject:u.path];
    }

    // 2) App Group 容器（需要对应 group entitlement，失败就跳过）
    NSString *agRoot = @"/var/mobile/Containers/Shared/AppGroup";
    for (NSString *sub in [fm contentsOfDirectoryAtPath:agRoot error:nil] ?: @[]) {
        NSString *root = [agRoot stringByAppendingPathComponent:sub];
        NSDirectoryEnumerator<NSURL *> *en2 =
            [fm enumeratorAtURL:[NSURL fileURLWithPath:root]
       includingPropertiesForKeys:@[NSURLFileSizeKey, NSURLIsDirectoryKey]
                          options:NSDirectoryEnumerationSkipsHiddenFiles
                     errorHandler:^BOOL(NSURL *u, NSError *e) { return YES; }];
        for (NSURL *u in en2) {
            NSNumber *isDir = nil, *size = nil;
            [u getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:nil];
            if (isDir.boolValue) continue;
            [u getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
            if (isVideoLike(u.path, size)) [targets addObject:u.path];
        }
    }

    DLog([NSString stringWithFormat:@"scan done, candidates: %lu", (unsigned long)targets.count]);

    NSInteger ok = 0, fail = 0;
    for (NSString *p in targets) {
        NSString *dst = [kDumpDir stringByAppendingPathComponent:p.lastPathComponent];
        int i = 2;
        while ([fm fileExistsAtPath:dst]) { // 重名加序号
            dst = [kDumpDir stringByAppendingPathComponent:
                   [NSString stringWithFormat:@"%@-%d", p.lastPathComponent, i++]];
        }
        NSError *e = nil;
        if ([fm copyItemAtPath:p toPath:dst error:&e]) ok++;
        else fail++;
        DLog([NSString stringWithFormat:@"%@ %@", p.lastPathComponent, e ? e.localizedDescription : @"-> OK"]);
    }
    DLog([NSString stringWithFormat:@"dump finished: ok=%ld fail=%ld dir=%@",
          (long)ok, (long)fail, kDumpDir]);

    if (!gDone) { // 第一次完成时弹个窗，确认跑通了
        gDone = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            UIWindow *w = UIApplication.sharedApplication.delegate.window;
            if (!w) {
                for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
                    if (![s isKindOfClass:[UIWindowScene class]]) continue;
                    for (UIWindow *win in ((UIWindowScene *)s).windows) {
                        if (win.isKeyWindow) { w = win; break; }
                    }
                }
            }
            UIViewController *vc = w.rootViewController;
            UIAlertController *a = [UIAlertController alertControllerWithTitle:@"缓存已导出"
                message:kDumpDir preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
            [vc presentViewController:a animated:YES completion:nil];
        });
    }
}

__attribute__((constructor))
static void init(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ DumpOnce(); }); // 启动 20s 后先跑一次
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                      object:nil queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *n) { DumpOnce(); }]; // 每次回前台增量跑
}
