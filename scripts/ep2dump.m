// ep2dump.m — 抖音精选(AwemeJX) MediaDecrypter dump 插件
// 用途: 巨魔注入抖音精选后, hook 解密方法, 把密钥/密文/明文落盘
// 编译: xcrun clang -dynamiclib -arch arm64 -isysroot $(xcrun --sdk iphoneos --show-sdk-path) \
//         -miphoneos-version-min=15.0 -fobjc-arc -framework Foundation -o ep2dump.dylib ep2dump.m
// 行为: 注入后自动等 MediaDecrypter 类加载并装 hook; 播放付费剧集即自动 dump
// 输出: App容器/Documents/ep2dump/*.bin + log.txt (可用 Filza/WebDAV 拖走)

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>

static NSString *const kTag = @"ep2dump";

// ---------- 目标 selector (实例方法; 类方法也会尝试) ----------
static NSString *const kSelectors[] = {
    @"decryptBlock:",
    @"aesDecryptCacheData:withKey:error:cost:",
    @"aesDecryptwithData:KeyData:keySize:ivData:",
    @"aesDecryptwithKey:keySize:iv:",
    @"aesDecryptwithKeyData:keySize:ivData:",
    @"AESDecryptData:keyData:ivData:",
    @"AESDecryptString:keyData:ivData:",
    @"aesGCMDecryptCipher:tag:key:iv:",
    @"buildEncryptedDecryptionKey:",
    @"decryptVideoFile:",
    @"decryptVideoFileAtPath:",
    @"aesDecryptString:withKey:",
    @"decryptionKey",   // getter
    @"decryptKey",      // getter
};
static const NSUInteger kSelectorCount = sizeof(kSelectors) / sizeof(kSelectors[0]);

// ---------- 工具 ----------
static NSString *DumpDir(void) {
    NSString *d = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/ep2dump"];
    [[NSFileManager defaultManager] createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
    return d;
}

static NSString *TS(void) {
    static NSDateFormatter *f;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ f = [NSDateFormatter new]; f.dateFormat = @"HH:mm:ss.SSS"; });
    return [f stringFromDate:[NSDate date]];
}

static void Log(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void Log(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[%@] %@", kTag, s);
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", TS(), s];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:[DumpDir() stringByAppendingPathComponent:@"log.txt"]];
    if (!fh) {
        [[NSFileManager defaultManager] createFileAtPath:[DumpDir() stringByAppendingPathComponent:@"log.txt"] contents:nil attributes:nil];
        fh = [NSFileHandle fileHandleForWritingAtPath:[DumpDir() stringByAppendingPathComponent:@"log.txt"]];
    }
    @try { [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; } @catch (NSException *e) {}
    [fh closeFile];
}

static NSString *HexHead(NSData *d, NSUInteger n) {
    const uint8_t *b = d.bytes;
    NSMutableString *s = [NSMutableString string];
    for (NSUInteger i = 0; i < MIN(n, d.length); i++) [s appendFormat:@"%02x", b[i]];
    return s;
}

static NSInteger g_seq = 0;
static long long g_totalBytes = 0;
static const long long kMaxTotal = 5LL * 1024 * 1024 * 1024; // 总落盘上限 5GB
static BOOL g_dumpEnabled = YES;   // Documents/ep2dump/RECON 存在时关闭 dump 只记日志
static id g_lock;
static void RefreshMode(void) {
    g_dumpEnabled = ![[NSFileManager defaultManager] fileExistsAtPath:[DumpDir() stringByAppendingPathComponent:@"RECON"]];
}
static void Dump(NSString *tag, NSData *data) {
    if (!g_dumpEnabled) return;
    if (![data isKindOfClass:[NSData class]] || data.length == 0 || data.length > (512u << 20)) return;
    @synchronized (g_lock) {
        if (g_totalBytes > kMaxTotal) { Log(@"[cap] 已达 5GB 上限, 停止 dump (日志继续)"); return; }
        g_totalBytes += data.length;
        NSInteger n = ++g_seq;
        NSString *fn = [NSString stringWithFormat:@"%@/%05ld_%@_%lu.bin", DumpDir(), (long)n, tag, (unsigned long)data.length];
        if ([data writeToFile:fn atomically:YES])
            Log(@"dump %@ -> %luB", fn.lastPathComponent, (unsigned long)data.length);
        // 密钥候选(16/24/32 字节)单独放一份, 方便肉眼找
        if (data.length == 16 || data.length == 24 || data.length == 32) {
            NSString *kf = [NSString stringWithFormat:@"%@/keys/%05ld_%@_%lu.bin", DumpDir(), (long)n, tag, (unsigned long)data.length];
            [[NSFileManager defaultManager] createDirectoryAtPath:[DumpDir() stringByAppendingPathComponent:@"keys"] withIntermediateDirectories:YES attributes:nil error:nil];
            [data writeToFile:kf atomically:YES];
        }
    }
}

static void DumpObj(NSString *tag, id obj) {
    if ([obj isKindOfClass:[NSData class]]) { Dump(tag, obj); }
    else if ([obj isKindOfClass:[NSString class]]) { Dump(tag, [(NSString *)obj dataUsingEncoding:NSUTF8StringEncoding]); }
}

// ---------- hook 机制 ----------
// meta[原selector] = @{ @"hookSel": NSValue(SEL), @"types": NSString }
static NSMutableDictionary *g_meta;

// 参数类型安全过滤: 只接受 对象/指针/标量, 拒绝结构体等
static BOOL SignatureIsSafe(NSMethodSignature *sig) {
    for (NSUInteger i = 0; i < sig.numberOfArguments; i++) {
        const char *t = [sig getArgumentTypeAtIndex:i];
        if (!t) return NO;
        switch (t[0]) {
            case '@': case '#': case ':': case '^': case '?':
            case 'i': case 'l': case 'q': case 'I': case 'L': case 'Q':
            case 'f': case 'd': case 'B': case 'c': case 'C': case 'v':
                if (t[1] != '\0' && t[0] != '^' && t[0] != '@' && t[0] != '#') return NO;
                break;
            default: return NO; // { ( [ b j 等一律不装
        }
    }
    return YES;
}

static void HookIMP(id self, SEL _cmd, ...) {
    NSValue *key = [NSValue valueWithPointer:_cmd];
    NSDictionary *meta = g_meta[key];
    if (!meta) return; // 不该发生
    SEL hookSel = (SEL)[meta[@"hookSel"] pointerValue];
    NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:[meta[@"types"] UTF8String]];
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.target = self;
    inv.selector = hookSel;   // exchange 后, hookSel 指向原实现

    va_list ap; va_start(ap, _cmd);
    BOOL argCopyOK = YES;
    for (NSUInteger i = 2; i < sig.numberOfArguments; i++) {
        const char *t = [sig getArgumentTypeAtIndex:i];
        switch (t[0]) {
            case '@': case '#': case ':': case '^': case '?': { void *p = va_arg(ap, void *); [inv setArgument:&p atIndex:i]; break; }
            case 'i': { int v = va_arg(ap, int); [inv setArgument:&v atIndex:i]; break; }
            case 'I': { unsigned v = va_arg(ap, unsigned); [inv setArgument:&v atIndex:i]; break; }
            case 'l': { long v = va_arg(ap, long); [inv setArgument:&v atIndex:i]; break; }
            case 'L': { unsigned long v = va_arg(ap, unsigned long); [inv setArgument:&v atIndex:i]; break; }
            case 'q': { long long v = va_arg(ap, long long); [inv setArgument:&v atIndex:i]; break; }
            case 'Q': { unsigned long long v = va_arg(ap, unsigned long long); [inv setArgument:&v atIndex:i]; break; }
            case 'f': { double v = va_arg(ap, double); float f = (float)v; [inv setArgument:&f atIndex:i]; break; }
            case 'd': { double v = va_arg(ap, double); [inv setArgument:&v atIndex:i]; break; }
            case 'B': case 'c': case 'C': { int v = va_arg(ap, int); [inv setArgument:&v atIndex:i]; break; }
            default: argCopyOK = NO; break;
        }
        if (!argCopyOK) break;
    }
    va_end(ap);

    if (!argCopyOK) {
        Log(@"[!] 参数类型不安全, 放弃 hook %s (直接放行)", sel_getName(_cmd));
        // 尽力用原始消息调用, 只传 self/_cmd
        ((void (*)(id, SEL))objc_msgSend)(self, hookSel);
        return;
    }

    @try {
        // 调用前: dump 所有 NSData/NSString 参数
        NSString *clsName = NSStringFromClass(object_getClass(self));
        for (NSUInteger i = 2; i < sig.numberOfArguments; i++) {
            void *p = NULL;
            [inv getArgument:&p atIndex:i];
            if (!p) continue;
            const char *t = [sig getArgumentTypeAtIndex:i];
            if (t[0] == '@') {
                id obj = (__bridge id)p;
                if ([obj isKindOfClass:[NSData class]] || [obj isKindOfClass:[NSString class]]) {
                    NSString *tag = [NSString stringWithFormat:@"%@_%s_a%lu", clsName, sel_getName(_cmd), (unsigned long)i];
                    Log(@"[>] %@ arg%lu %@/%luB head=%@", clsName, (unsigned long)i,
                        [obj isKindOfClass:[NSData class]] ? @"NSData" : @"NSString",
                        (unsigned long)[obj isKindOfClass:[NSData class]] ? ((NSData *)obj).length : [(NSString *)obj length],
                        HexHead([obj isKindOfClass:[NSData class]] ? obj : [(NSString *)obj dataUsingEncoding:NSUTF8StringEncoding], 48));
                    DumpObj(tag, obj);
                }
            }
        }
        [inv invoke];
        [inv retainArguments]; // no-op 兼容; NSInvocation 调用后参数可能失效, 提前已 dump
        // 返回值
        const char *rt = sig.methodReturnType;
        if (rt && rt[0] == '@') {
            void *rv = NULL;
            [inv getReturnValue:&rv];
            if (rv) {
                id obj = (__bridge id)rv;
                if ([obj isKindOfClass:[NSData class]] || [obj isKindOfClass:[NSString class]]) {
                    NSString *tag = [NSString stringWithFormat:@"%@_%s_ret", clsName, sel_getName(_cmd)];
                    NSUInteger len = [obj isKindOfClass:[NSData class]] ? ((NSData *)obj).length : [(NSString *)obj length];
                    Log(@"[<] %@ ret %@/%luB head=%@", clsName,
                        [obj isKindOfClass:[NSData class]] ? @"NSData" : @"NSString",
                        (unsigned long)len,
                        HexHead([obj isKindOfClass:[NSData class]] ? obj : [(NSString *)obj dataUsingEncoding:NSUTF8StringEncoding], 48));
                    DumpObj(tag, obj);
                }
            }
        }
    } @catch (NSException *e) {
        Log(@"[!] exception in %s: %@", sel_getName(_cmd), e.reason);
        @try { [inv invoke]; } @catch (NSException *e2) {}
    }
}

static void InstallOnClass(Class cls, NSString *selStr, BOOL isClassMethod) {
    SEL sel = NSSelectorFromString(selStr);
    Method m = isClassMethod ? class_getClassMethod(cls, sel) : class_getInstanceMethod(cls, sel);
    if (!m) return;
    NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(m)];
    if (!SignatureIsSafe(sig)) { Log(@"[skip] %@ %@ %@ (签名不安全)", isClassMethod ? @"+" : @"-", NSStringFromClass(cls), selStr); return; }

    SEL hookSel = NSSelectorFromString([NSString stringWithFormat:@"ep2_%p_%@", (void *)m, selStr]);
    const char *types = method_getTypeEncoding(m);
    BOOL added = class_addMethod(isClassMethod ? object_getClass(cls) : cls, hookSel, (IMP)HookIMP, types);
    if (!added) { Log(@"[skip] addMethod 失败 %@ %@", NSStringFromClass(cls), selStr); return; }
    Method hm = isClassMethod ? class_getClassMethod(cls, hookSel) : class_getInstanceMethod(cls, hookSel);
    method_exchangeImplementations(m, hm);
    NSString *typesStr = [NSString stringWithUTF8String:types];
    g_meta[[NSValue valueWithPointer:sel]] = @{ @"hookSel": [NSValue valueWithPointer:hookSel], @"types": typesStr };
    Log(@"[hook] %@ %@ %@", isClassMethod ? @"+" : @"-", NSStringFromClass(cls), selStr);
}

static void InstallAll(void) {
    // 1) 静态首选: MediaDecrypter
    Class md = objc_getClass("MediaDecrypter");
    if (md) {
        for (NSUInteger i = 0; i < kSelectorCount; i++) {
            InstallOnClass(md, (NSString *)kSelectors[i], NO);
            InstallOnClass(md, (NSString *)kSelectors[i], YES);
        }
    }
    // 2) 兜底: 枚举所有已注册类, 谁有这些 selector 就装
    int n = objc_getClassList(NULL, 0);
    if (n > 0) {
        Class *buf = (Class *)malloc(sizeof(Class) * n);
        objc_getClassList(buf, n);
        for (int i = 0; i < n; i++) {
            Class c = buf[i];
            if (c == md) continue;
            for (NSUInteger j = 0; j < kSelectorCount; j++) {
                SEL s = NSSelectorFromString(kSelectors[j]);
                if (class_getInstanceMethod(c, s)) InstallOnClass(c, (NSString *)kSelectors[j], NO);
                if (class_getClassMethod(c, s)) InstallOnClass(c, (NSString *)kSelectors[j], YES);
            }
        }
        free(buf);
    }
    Log(@"install 完成, meta=%lu", (unsigned long)g_meta.count);
}

static void WaitAndInstall(void) {
    for (int i = 0; i < 120; i++) {   // 最多等 60 秒
        if (objc_getClass("MediaDecrypter") || i > 20) { InstallAll(); return; }
        usleep(500 * 1000);
    }
}

__attribute__((constructor))
static void init_ep2dump(void) {
    @autoreleasepool {
        g_meta = [NSMutableDictionary dictionary];
        g_lock = [NSObject new];
        Log(@"===== ep2dump 注入成功, build %s %s =====", __DATE__, __TIME__);
        Log(@"容器: %@", NSHomeDirectory());
        RefreshMode();
        Log(@"dump %@ (在 Documents/ep2dump/ 放一个名为 RECON 的空文件可只记日志不落盘)", g_dumpEnabled ? @"开启" : @"关闭(RECON)");
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            WaitAndInstall();
        });
    }
}
