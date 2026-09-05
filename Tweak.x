//
//  Tweak.x  (Logos)
//  拼多多商品详情结构化数据自动落盘(与网页端采集格式同构)
//
//  触发方式(默认全静默):
//    1) 关闭自动抓取:打开 App 后插件不自动运行(v0.3.0 起,可改 config.json 的
//       autoCapture=true 恢复自动)。
//    2) 截屏触发:拼多多在前台时,每截屏一次 = 抓一次当前页面的商品数据。
//       (任何页面都行:详情/列表/首页都会取当前页可识别的商品节点)
//    3) 日志:右下角「日志」悬浮按钮手动查看(启动不自动弹)。
//
//  输出(与用户现有"采集会话 xxx商品数据TXT"流程一致):
//    目录  /var/mobile/Documents/PddDump/yyyy-MM-dd/
//    文件  {goodsID}.txt —— 覆盖写,同一商品当日保留最新快照
//    内容  {"store":{"initDataObj":{"goods":{...},"mall":{...}}}} 单行紧凑 JSON,
//          可直接丢进 pdd_extract 工具链 input/ 目录批量解析出 Excel
//
//  未实机验证:请在备用越狱机先行测试。字段版本漂移时改 config.json 即可,
//  无需重编译(首次运行自动生成模板)。

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <math.h>
#import <stdint.h>
#import "PDDConfig.h"

#pragma mark - 常量

static NSString *const kDumpDir = @"/var/mobile/Documents/PddDump";
static NSString *const kCfgPath = @"/var/mobile/Documents/PddDump/config.json";
static NSString *const kLogPath = @"/var/mobile/Documents/PddDump/log.txt";
static NSString *const kPluginVer = @"0.3.0-1";

#pragma mark - 全局状态

static NSDictionary *gCfg;              // 合并后的配置缓存
static dispatch_queue_t gScanQueue;     // 扫描+写盘后台队列
static NSDateFormatter *gFileFmt;       // 文件名时间(仅 unknown 兜底用)
static NSDateFormatter *gDayFmt;        // 当日日期文件夹 yyyy-MM-dd
static NSDateFormatter *gTimeFmt;       // 日志时间 HH:mm:ss
static NSISO8601DateFormatter *gIsoFmt; // capturedAt(JSON 清洗用)
static char kAutoDoneKey;               // 每 VC 只自动抓一次

// 日志缓存(内存 + log.txt)
static NSMutableArray *gLogLines;
static NSLock *gLogLock;
static void PDDLog(NSString *fmt, ...) __attribute__((format(printf, 1, 2)));

// 前置声明(定义在后,避免隐式声明)
void PDDToast(NSString *msg);
static UIViewController *PDDTopVC(void);
@class PDDLogTarget;

#pragma mark - 基础工具

static NSString *PDDStr(id v) {
    if (!v || v == [NSNull null]) return nil;
    if ([v isKindOfClass:NSString.class]) return v;
    if ([v isKindOfClass:NSNumber.class]) return ((NSNumber *)v).stringValue;
    return nil;
}

static NSDictionary *PDDConfig(void) {
    if (gCfg) return gCfg;
    gScanQueue = dispatch_queue_create("com.monitor.pdddump.scan", DISPATCH_QUEUE_SERIAL);
    gFileFmt = [NSDateFormatter new];
    gFileFmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    gFileFmt.dateFormat = @"yyyyMMdd_HHmmss";
    gDayFmt = [NSDateFormatter new];
    gDayFmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    gDayFmt.dateFormat = @"yyyy-MM-dd";
    gTimeFmt = [NSDateFormatter new];
    gTimeFmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    gTimeFmt.dateFormat = @"HH:mm:ss";
    gIsoFmt = [NSISO8601DateFormatter new];

    NSDictionary *base = PDDDefaultConfig();

    // 外部配置合并(config.json 存在则覆盖对应键,深一层递归)
    NSData *data = [NSData dataWithContentsOfFile:kCfgPath];
    id extObj = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSMutableDictionary *merged = [base mutableCopy];
    BOOL hasExtFile = [extObj isKindOfClass:NSDictionary.class];
    if (hasExtFile) {
        for (NSString *key in extObj) {
            id bv = merged[key], ev = extObj[key];
            if ([bv isKindOfClass:NSDictionary.class] && [ev isKindOfClass:NSDictionary.class]) {
                NSMutableDictionary *sub = [bv mutableCopy];
                [sub addEntriesFromDictionary:ev];
                merged[key] = sub;
            } else {
                merged[key] = ev;
            }
        }
    }

    // —— 版本升级迁移 ——
    // 旧版生成的 config.json 会带着旧默认值(如 autoCapture=true)。
    // 插件版本升级时:行为开关强制跟随新内置默认;用户改过的键表/数值调优保留。
    if (hasExtFile && ![[NSString stringWithFormat:@"%@", extObj[@"lastPluginVer"] ?: @""]
                         isEqualToString:kPluginVer]) {
        NSArray *behaviorKeys = @[@"autoCapture", @"screenshotTrigger", @"detailOnly",
                                  @"banner", @"logPanel", @"autoShowLog"];
        for (NSString *k in behaviorKeys) {
            if (base[k]) merged[k] = base[k];
        }
        merged[@"lastPluginVer"] = kPluginVer;
        // 与首启模板保持同一风格:内部过滤表不写进用户配置文件
        // (注意:运行用 gCfg 仍需保留 skip 表,只从"写回文件的副本"移除)
        NSMutableDictionary *writeBack = [merged mutableCopy];
        [writeBack removeObjectForKey:@"skipPrefixes"];
        [writeBack removeObjectForKey:@"skipClasses"];
        NSData *j = [NSJSONSerialization dataWithJSONObject:writeBack
                                                    options:NSJSONWritingPrettyPrinted error:nil];
        [j writeToFile:kCfgPath atomically:YES];
        gCfg = [merged copy];
        PDDLog(@"[配置] 检测到旧版 config.json,行为开关已按 v%@ 默认重置(键表/数值调优保留)",
               kPluginVer);
        return gCfg;
    }

    gCfg = [merged copy];
    return gCfg;
}

static BOOL PDDCfgBool(NSDictionary *cfg, NSString *key, BOOL dft) {
    id v = cfg[key];
    return v ? [v boolValue] : dft;
}

static NSUInteger PDDCfgInt(NSDictionary *cfg, NSString *key, NSUInteger dft) {
    id v = cfg[key];
    return v ? [v unsignedIntegerValue] : dft;
}

#pragma mark - 运行日志(内存 + log.txt)

static void PDDLogInit(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gLogLines = [NSMutableArray arrayWithCapacity:256];
        gLogLock = [NSLock new];
    });
}

/// 记录一行运行日志:内存缓存(供面板显示)+ 追加写 log.txt
void PDDLog(NSString *fmt, ...) {
    PDDLogInit();
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    NSString *stamp = [gTimeFmt stringFromDate:[NSDate date]];
    NSString *line = [NSString stringWithFormat:@"%@ | %@", stamp, msg];
    NSLog(@"[PddDump] %@", msg);

    [gLogLock lock];
    [gLogLines addObject:line];
    if (gLogLines.count > 600) {
        [gLogLines removeObjectsInRange:NSMakeRange(0, gLogLines.count - 400)];
    }
    [gLogLock unlock];

    // 异步追加文件(低频事件,无性能压力)
    dispatch_async(gScanQueue, ^{
        NSError *e = nil;
        [[NSFileManager defaultManager] createDirectoryAtPath:kDumpDir
                                 withIntermediateDirectories:YES attributes:nil error:&e];
        // 超过 logFileMaxKB 则整体截断(保留文件不无限增长)
        NSDictionary *cfg = PDDConfig();
        long long cap = PDDCfgInt(cfg, @"logFileMaxKB", 512) * 1024;
        NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:kLogPath error:nil];
        NSNumber *sz = attr[NSFileSize];
        if (sz && sz.longLongValue > cap && [[NSFileManager defaultManager] fileExistsAtPath:kLogPath]) {
            [[NSFileManager defaultManager] removeItemAtPath:kLogPath error:nil];
        }
        NSString *full = [line stringByAppendingString:@"\n"];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kLogPath];
        if (fh) {
            @try {
                [fh seekToEndOfFile];
                [fh writeData:[full dataUsingEncoding:NSUTF8StringEncoding]];
                [fh closeFile];
            } @catch (NSException *ex) {}
        } else {
            [full writeToFile:kLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
    });
}

/// 供日志面板取最近 N 行
static NSArray *PDDRecentLogs(NSUInteger n) {
    PDDLogInit();
    [gLogLock lock];
    NSRange r;
    if (gLogLines.count <= n) r = NSMakeRange(0, gLogLines.count);
    else r = NSMakeRange(gLogLines.count - n, n);
    NSArray *out = [gLogLines subarrayWithRange:r];
    [gLogLock unlock];
    return out;
}

/// 从候选数组里找出首个在 dict(或其直接子 dict / 子数组内 dict)存在的键,返回键名
static NSString *PDDFindKey(NSDictionary *dict, NSArray *cands, int depth) {
    if (!dict || cands.count == 0) return nil;
    for (NSString *k in cands) {
        if (dict[k] && dict[k] != [NSNull null]) return k;
    }
    if (depth <= 0) return nil;
    // 一层下沉:子 dict 与数组内 dict(部分字段包在 priceInfo / list 里)
    for (id v in dict.allValues) {
        if ([v isKindOfClass:NSDictionary.class]) {
            NSString *k = PDDFindKey(v, cands, depth - 1);
            if (k) return k;
        } else if ([v isKindOfClass:NSArray.class]) {
            for (id item in v) {
                if ([item isKindOfClass:NSDictionary.class]) {
                    NSString *k = PDDFindKey(item, cands, depth - 1);
                    if (k) return k;
                }
            }
        }
    }
    return nil;
}

static id PDDValueForCands(NSDictionary *dict, NSArray *cands) {
    if (!dict) return nil;
    NSString *k = PDDFindKey(dict, cands, 2);
    return k ? dict[k] : nil;
}

#pragma mark - 键表访问

static NSArray *PDDCands(NSDictionary *cfg, NSString *norm) {
    id v = cfg[norm];
    return [v isKindOfClass:NSArray.class] ? v : @[];
}

static BOOL PDDContainsAnyCand(NSDictionary *dict, NSArray *cands) {
    for (NSString *k in cands) {
        if (dict[k] && dict[k] != [NSNull null]) return YES;
    }
    return NO;
}

#pragma mark - 商品特征判定

static BOOL PDDValidGoodsId(NSDictionary *cfg, id value) {
    NSString *s = PDDStr(value);
    if (!s) return NO;
    NSString *pat = [cfg[@"goodsIdRegex"] isKindOfClass:NSString.class] ? cfg[@"goodsIdRegex"] : @"^[0-9]{6,24}$";
    NSPredicate *p = [NSPredicate predicateWithFormat:@"SELF MATCHES %@", pat];
    return [p evaluateWithObject:s];
}

/// 判断一个字典是否为"商品数据节点"
static BOOL PDDIsGoodsDict(NSDictionary *cfg, NSDictionary *dict) {
    // 必须含合法 goodsId
    id gid = PDDValueForCands(dict, PDDCands(cfg, @"goodsId"));
    if (!PDDValidGoodsId(cfg, gid)) return NO;
    // 必须有名称或价格之一(进一步排除无关容器)
    BOOL hasName = PDDContainsAnyCand(dict, PDDCands(cfg, @"name")) ||
                   PDDContainsAnyCand(dict, PDDCands(cfg, @"price"));
    if (!hasName) return NO;
    // detailOnly: 详情页数据通常带 sku / 店铺字段
    if (PDDCfgBool(cfg, @"detailOnly", YES)) {
        BOOL hasSku = PDDContainsAnyCand(dict, PDDCands(cfg, @"sku"));
        BOOL hasMall = PDDContainsAnyCand(dict, PDDCands(cfg, @"mall"));
        if (!hasSku && !hasMall) return NO;
    }
    return YES;
}

#pragma mark - 递归扫描

static BOOL PDDShouldSkip(id obj, NSDictionary *cfg) {
    if (!obj) return YES;
    if ([obj isKindOfClass:NSString.class] || [obj isKindOfClass:NSNumber.class] ||
        [obj isKindOfClass:NSData.class]   || [obj isKindOfClass:NSDate.class]   ||
        [obj isKindOfClass:NSURL.class]    || [obj isKindOfClass:NSValue.class]  ||
        [obj isKindOfClass:NSAttributedString.class] || [obj isKindOfClass:NSNull.class] ||
        [obj isKindOfClass:NSSet.class])  // NSSet 罕见且易环,跳过
        return YES;
    if ([obj isKindOfClass:NSDictionary.class] || [obj isKindOfClass:NSArray.class])
        return NO;
    // 类对象直接跳过
    if (class_isMetaClass(object_getClass(obj))) return YES;

    NSString *cn = NSStringFromClass(object_getClass(obj));
    for (NSString *p in cfg[@"skipPrefixes"]) {
        if ([cn hasPrefix:p]) return YES;
    }
    for (NSString *exact in cfg[@"skipClasses"]) {
        if ([cn isEqualToString:exact]) return YES;
    }
    return NO;
}

/// 深度优先扫描对象图,收集商品节点。
/// budget 为剩余访问额度(指针),v 为防环集合,hits 收集结果。
static void PDDScan(id obj, NSDictionary *cfg, int depth, NSMutableSet *v, NSMutableArray *hits, int *budget) {
    if (obj == nil || depth <= 0 || *budget <= 0 || hits.count >= 5) return;
    (*budget)--;
    if (PDDShouldSkip(obj, cfg)) return;

    uintptr_t addr = (uintptr_t)obj;
    NSNumber *tag = @(addr);
    if ([v containsObject:tag]) return;
    [v addObject:tag];

    if ([obj isKindOfClass:NSDictionary.class]) {
        NSDictionary *dict = (NSDictionary *)obj;
        if (PDDIsGoodsDict(cfg, dict)) {
            [hits addObject:dict];     // 命中即返回,避免重复进子结构
            return;
        }
        for (id val in dict.allValues) {
            PDDScan(val, cfg, depth - 1, v, hits, budget);
        }
        return;
    }
    if ([obj isKindOfClass:NSArray.class]) {
        for (id item in (NSArray *)obj) {
            PDDScan(item, cfg, depth - 1, v, hits, budget);
        }
        return;
    }

    // 普通对象:枚举属性 + '@' 型 ivar(KVC 读取,兜底 GPBMessage 等模型)
    unsigned pc = 0;
    objc_property_t *props = class_copyPropertyList(object_getClass(obj), &pc);
    NSMutableSet *doneNames = [NSMutableSet set];
    for (unsigned i = 0; i < pc; i++) {
        const char *nm = property_getName(props[i]);
        if (!nm) continue;
        NSString *name = [NSString stringWithUTF8String:nm];
        if (name.length == 0 || [name hasPrefix:@"_"]) continue;
        [doneNames addObject:name];
        id val = nil;
        @try { val = [obj valueForKey:name]; }
        @catch (NSException *e) { val = nil; }
        if (val && val != obj) PDDScan(val, cfg, depth - 1, v, hits, budget);
    }
    free(props);

    if (*budget > 0 && hits.count == 0) {
        unsigned ic = 0;
        Ivar *ivars = class_copyIvarList(object_getClass(obj), &ic);
        for (unsigned i = 0; i < ic; i++) {
            const char *t = ivar_getTypeEncoding(ivars[i]);
            if (!t || t[0] != '@') continue;             // 仅对象型
            const char *n = ivar_getName(ivars[i]);
            if (!n) continue;
            NSString *raw = [NSString stringWithUTF8String:n];
            NSString *clean = raw;
            if ([clean hasPrefix:@"_"]) clean = [clean substringFromIndex:1];
            if ([doneNames containsObject:clean]) continue;
            id val = nil;
            @try { val = object_getIvar(obj, ivars[i]); }
            @catch (NSException *e) { val = nil; }
            if (val && val != obj) PDDScan(val, cfg, depth - 1, v, hits, budget);
        }
        free(ivars);
    }
}

/// 快速预检:VC 附近是否存在商品数据(避免每个页面都全量扫描)
static BOOL PDDQuickProbe(NSDictionary *cfg, id root) {
    NSMutableSet *v = [NSMutableSet set];
    NSMutableArray *hits = [NSMutableArray array];
    int budget = (int)PDDCfgInt(cfg, @"quickBudget", 400);
    PDDScan(root, cfg, 3, v, hits, &budget);
    return hits.count > 0;
}

#pragma mark - JSON 安全清洗

/// 把任意对象递归转换为可 JSON 序列化的结构(丢弃自定义对象/非标值)
static id PDDJsonSafe(id o, int depth) {
    if (o == nil || o == [NSNull null]) return nil;
    if (depth <= 0) return nil;
    if ([o isKindOfClass:NSString.class] || [o isKindOfClass:NSNumber.class]) {
        // 排除 NaN / Infinity
        if ([o isKindOfClass:NSNumber.class]) {
            double d = [o doubleValue];
            if (isnan(d) || isinf(d)) return nil;
        }
        return o;
    }
    if ([o isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *m = [NSMutableDictionary dictionary];
        for (id k in o) {
            if (![k isKindOfClass:NSString.class]) continue;
            id v = PDDJsonSafe(o[k], depth - 1);
            if (v) m[k] = v;
        }
        return m;
    }
    if ([o isKindOfClass:NSArray.class]) {
        NSMutableArray *m = [NSMutableArray array];
        for (id it in o) {
            id v = PDDJsonSafe(it, depth - 1);
            if (v) [m addObject:v];
        }
        return m;
    }
    if ([o isKindOfClass:NSDate.class]) {
        return [gIsoFmt stringFromDate:(NSDate *)o];
    }
    if ([o isKindOfClass:NSURL.class]) {
        return [(NSURL *)o absoluteString];
    }
    if ([o isKindOfClass:NSData.class]) {
        return [(NSData *)o base64EncodedStringWithOptions:0];
    }
    return nil;  // 自定义对象丢弃,保证主数据不因单点异常整体失败
}

#pragma mark - H5 同构归一化(对齐现有 pdd_extract 工具链)

// 输出约定(与网页端采集文件一致):
//   {"store":{"initDataObj":{"goods":{...},"mall":{...}}}} 单行 JSON
//   直接可丢进 pdd_extract 的 input/ 目录批量解析成 Excel

static NSNumber *PDDNum(id v) {
    if ([v isKindOfClass:NSNumber.class]) return v;
    if ([v isKindOfClass:NSString.class]) {
        NSString *s = [v stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (!s.length) return nil;
        double d = [s doubleValue];
        return (isnan(d) || isinf(d)) ? nil : @(d);
    }
    return nil;
}

/// SKU 元素(iOS 形态)尽量补成 H5 形态:spec -> specs,isOnSale -> isOnsale
static NSDictionary *PDDNormalizeSku(NSDictionary *sku) {
    NSMutableDictionary *m = [sku mutableCopy];
    if (!m[@"specs"] && m[@"spec"]) {
        id sp = m[@"spec"];
        if ([sp isKindOfClass:NSArray.class]) {
            m[@"specs"] = sp;
        } else if ([sp isKindOfClass:NSString.class] && [sp length]) {
            m[@"specs"] = @[@{@"spec_key": @"", @"spec_value": sp}];
        }
    }
    if (!m[@"isOnsale"] && m[@"isOnSale"]) m[@"isOnsale"] = m[@"isOnSale"];
    return m;
}

/// 商品 dict 增强:不改原键,只补齐 H5 标准键(goodsID/skus/sideSalesTip/价格区间)
static NSDictionary *PDDEnhanceGoods(NSDictionary *cfg, NSDictionary *hit) {
    id safe = PDDJsonSafe(hit, 12);
    NSMutableDictionary *g = [safe isKindOfClass:NSDictionary.class]
        ? [[NSMutableDictionary alloc] initWithDictionary:safe]
        : [NSMutableDictionary dictionary];

    // 1. goodsID / goodsId 双写
    NSString *gidStr = PDDStr(PDDValueForCands(hit, PDDCands(cfg, @"goodsId")));
    if (gidStr.length) {
        g[@"goodsID"] = gidStr;
        g[@"goodsId"] = gidStr;
    }
    // 2. 标题 / 已拼件数(与 H5 键一致)
    NSString *name = PDDStr(PDDValueForCands(hit, PDDCands(cfg, @"name")));
    if (name.length) g[@"goodsName"] = (name.length > 300) ? [name substringToIndex:300] : name;
    NSString *sales = PDDStr(PDDValueForCands(hit, PDDCands(cfg, @"sales")));
    if (sales.length) g[@"sideSalesTip"] = sales;
    // 3. 拼单价区间(minGroupPrice / maxGroupPrice,仅当存在数值型价格键)
    NSMutableArray *prices = [NSMutableArray array];
    for (NSString *k in PDDCands(cfg, @"price")) {
        if (!hit[k]) continue;
        NSNumber *n = PDDNum(hit[k]);
        if (n) [prices addObject:n];
    }
    if (prices.count) {
        [prices sortUsingSelector:@selector(compare:)];
        g[@"minGroupPrice"] = prices.firstObject;
        g[@"maxGroupPrice"] = prices.lastObject;
    }
    // 4. skus:取命中数组并逐条补 H5 键
    id skuRaw = g[@"skus"];
    if (!skuRaw) {
        id skuVal = PDDValueForCands(hit, PDDCands(cfg, @"sku"));
        if ([skuVal isKindOfClass:NSArray.class]) skuRaw = skuVal;
    }
    if ([skuRaw isKindOfClass:NSArray.class]) {
        NSMutableArray *outSkus = [NSMutableArray array];
        for (id item in skuRaw) {
            if ([item isKindOfClass:NSDictionary.class]) {
                [outSkus addObject:PDDNormalizeSku(item)];
            }
        }
        if (outSkus.count) g[@"skus"] = outSkus;
    }
    // 5. 店铺 ID / 名称 提到 goods 顶层(便于后续单独提取 mall)
    NSNumber *mallId = PDDNum(PDDValueForCands(hit, PDDCands(cfg, @"mallIdKeys")));
    if (mallId) g[@"mallID"] = mallId;
    id mallNameVal = PDDValueForCands(hit, PDDCands(cfg, @"mallNameKeys"));
    NSString *mallName = PDDStr(mallNameVal);
    if (mallName.length && !g[@"mallName"]) g[@"mallName"] = mallName;
    return g;
}

/// 构建输出容器(与 H5 文件同构)
static NSDictionary *PDDBuildPayload(NSDictionary *cfg, NSDictionary *hit) {
    NSDictionary *goods = PDDEnhanceGoods(cfg, hit);
    NSMutableDictionary *mall = [NSMutableDictionary dictionary];
    if (goods[@"mallID"]) mall[@"mallID"] = goods[@"mallID"];
    if (goods[@"mallName"]) mall[@"mallName"] = goods[@"mallName"];
    return @{
        @"store": @{
            @"initDataObj": @{
                @"goods": goods,
                @"mall": mall
            }
        }
    };
}

/// 按"当日日期文件夹 + 商品ID.txt"落盘(覆盖写,保留最新快照)
static void PDDWrite(NSDictionary *cfg, NSDictionary *payload, NSString *goodsId) {
    NSDate *now = [NSDate date];
    NSString *day = [gDayFmt stringFromDate:now];
    NSString *dir = [kDumpDir stringByAppendingPathComponent:day];

    // 文件名:goodsID.txt;识别失败退化为 unknown_时间戳.txt(避免互相覆盖)
    NSString *gid = goodsId.length ? goodsId : @"unknown";
    NSString *fileName;
    if (goodsId.length) {
        fileName = [NSString stringWithFormat:@"%@.txt", gid];
    } else {
        fileName = [NSString stringWithFormat:@"%@_%@.txt", gid, [gFileFmt stringFromDate:now]];
    }

    dispatch_async(gScanQueue, ^{
        NSError *err = nil;
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                 withIntermediateDirectories:YES attributes:nil error:&err];
        NSData *data = [NSJSONSerialization dataWithJSONObject:payload
                                                       options:0   // 紧凑单行,与网页端一致
                                                         error:&err];
        if (!data) {
            PDDToast([NSString stringWithFormat:@"JSON 序列化失败: %@", err.localizedDescription]);
            PDDLog(@"[保存] JSON 序列化失败: %@", err.localizedDescription);
            return;
        }
        // 覆盖写(同一商品当日保留最新快照)
        BOOL ok = [data writeToFile:[dir stringByAppendingPathComponent:fileName]
                            options:NSDataWritingAtomic error:&err];
        NSString *msg = ok
            ? [NSString stringWithFormat:@"PDD 已保存\n%@/%@", day, fileName]
            : [NSString stringWithFormat:@"PDD 保存失败: %@", err.localizedDescription];
        PDDToast(msg);
        if (ok) {
            PDDLog(@"[保存] 已覆盖写入 %@/%@ (%.1f KB)", day, fileName, data.length / 1024.0);
        } else {
            PDDLog(@"[保存] 写盘失败 %@/%@: %@", day, fileName, err.localizedDescription);
        }
    });
}

/// 底部横幅提示
void PDDToast(NSString *msg) {
    if (!PDDCfgBool(PDDConfig(), @"banner", YES)) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *win = nil;
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
            if ([s isKindOfClass:UIWindowScene.class]) {
                UIWindowScene *ws = (UIWindowScene *)s;
                win = ws.windows.firstObject;
                break;
            }
        }
        if (!win) win = UIApplication.sharedApplication.windows.firstObject;
        if (!win) return;

        UIView *old = [win viewWithTag:88217];
        [old removeFromSuperview];

        CGFloat w = win.bounds.size.width - 40;
        UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(20, win.bounds.size.height - 140, w, 44)];
        l.tag = 88217;
        l.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.78];
        l.textColor = [UIColor whiteColor];
        l.font = [UIFont systemFontOfSize:13];
        l.textAlignment = NSTextAlignmentCenter;
        l.numberOfLines = 2;
        l.layer.cornerRadius = 10;
        l.layer.masksToBounds = YES;
        l.text = msg;
        [win addSubview:l];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [l removeFromSuperview];
        });
    });
}

#pragma mark - 日志面板(悬浮按钮 + 实时日志)

static UIView *gLogPanel;       // 展开面板
static UIView *gLogTab;         // 悬浮小按钮
static NSTimer *gLogTimer;      // 面板刷新定时器
static BOOL gLogExpanded;
static BOOL gLogInstalled;
static PDDLogTarget *gLogTarget;  // 面板按钮事件目标
static const NSInteger kLogTabTag = 88310;
static const NSInteger kLogPanelTag = 88311;
static const NSInteger kLogTextTag = 88312;

@interface PDDLogTarget : NSObject
@end

static void PDDLogRefreshText(void) {
    UITextView *tv = (UITextView *)[gLogPanel viewWithTag:kLogTextTag];
    if (!tv) return;
    NSArray *lines = PDDRecentLogs(80);
    tv.text = [lines componentsJoinedByString:@"\n"];
    if (lines.count) {
        [tv scrollRangeToVisible:NSMakeRange(tv.text.length, 0)];
    }
}

static UIWindow *PDDFindWindow(void) {
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if ([s isKindOfClass:UIWindowScene.class]) {
            UIWindowScene *ws = (UIWindowScene *)s;
            if (ws.windows.count) return ws.windows.firstObject;
        }
    }
    return UIApplication.sharedApplication.windows.firstObject;
}

static void PDDLogCollapse(void) {
    [gLogTimer invalidate];
    gLogTimer = nil;
    [gLogPanel removeFromSuperview];
    gLogPanel = nil;
    gLogExpanded = NO;
}

static void PDDLogExpand(void) {
    UIWindow *win = PDDFindWindow();
    if (!win) return;
    if (gLogPanel) {
        [win addSubview:gLogPanel];   // 已存在则换到当前 window 顶层
    } else {
        CGFloat w = win.bounds.size.width;
        CGFloat h = win.bounds.size.height;
        CGFloat pw = MIN(350, w - 20);
        CGFloat ph = MIN(300, h * 0.52);
        UIView *panel = [[UIView alloc] initWithFrame:CGRectMake((w - pw) / 2, MAX(36, (h - ph) / 2 - 30), pw, ph)];
        panel.tag = kLogPanelTag;
        panel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.92];
        panel.layer.cornerRadius = 14;
        panel.layer.borderColor = [[UIColor colorWithWhite:1 alpha:0.25] CGColor];
        panel.layer.borderWidth = 0.5;
        panel.clipsToBounds = YES;

        // 标题行
        UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(12, 0, pw - 90, 30)];
        title.text = [NSString stringWithFormat:@"PddDump 日志 v%@", kPluginVer];
        title.font = [UIFont boldSystemFontOfSize:12];
        title.textColor = [UIColor whiteColor];
        [panel addSubview:title];

        UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
        close.frame = CGRectMake(pw - 34, 2, 30, 26);
        [close setTitle:@"×" forState:UIControlStateNormal];
        [close setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        close.titleLabel.font = [UIFont boldSystemFontOfSize:14];
        if (gLogTarget) {
            [close addTarget:gLogTarget action:@selector(pdd_closeLogTapped)
            forControlEvents:UIControlEventTouchUpInside];
        }
        [panel addSubview:close];

        // 分隔线
        UIView *sep = [[UIView alloc] initWithFrame:CGRectMake(0, 30, pw, 0.5)];
        sep.backgroundColor = [UIColor colorWithWhite:1 alpha:0.2];
        [panel addSubview:sep];

        // 日志正文
        UITextView *tv = [[UITextView alloc] initWithFrame:CGRectMake(4, 32, pw - 8, ph - 36)];
        tv.tag = kLogTextTag;
        tv.editable = NO;
        tv.selectable = YES;
        tv.backgroundColor = [UIColor clearColor];
        tv.textColor = [UIColor colorWithRed:0.76 green:1.0 blue:0.76 alpha:1.0]; // 淡绿
        tv.font = [UIFont fontWithName:@"Menlo" size:10];
        tv.showsVerticalScrollIndicator = YES;
        [panel addSubview:tv];

        // 收起的处理回调由 NSObject 分类提供
        gLogPanel = panel;
        [win addSubview:panel];
    }
    gLogExpanded = YES;
    PDDLogRefreshText();
    if (!gLogTimer) {
        gLogTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
            if (gLogExpanded && gLogPanel) PDDLogRefreshText();
        }];
    }
}

/// 关闭面板(保留悬浮按钮)
static void PDDLogCloseTapped(void) { PDDLogCollapse(); }

@implementation PDDLogTarget
- (void)pdd_closeLogTapped { PDDLogCloseTapped(); }
- (void)pdd_tabTapped { gLogExpanded ? PDDLogCollapse() : PDDLogExpand(); }
- (void)pdd_pan:(UIPanGestureRecognizer *)g {
    UIWindow *win = PDDFindWindow();
    if (!win || !g.view) return;
    CGPoint p = [g translationInView:win];
    CGPoint c = g.view.center;
    c.x += p.x; c.y += p.y;
    g.view.center = c;
    [g setTranslation:CGPointZero inView:win];
    CGFloat w = win.bounds.size.width, h = win.bounds.size.height;
    CGPoint cc = g.view.center;
    cc.x = MAX(34, MIN(w - 34, cc.x));
    cc.y = MAX(44, MIN(h - 30, cc.y));
    g.view.center = cc;
}
@end

static void PDDLogInstall(void) {
    if (gLogInstalled) return;
    NSDictionary *cfg = PDDConfig();
    if (!PDDCfgBool(cfg, @"logPanel", YES)) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *win = PDDFindWindow();
        if (!win) {
            // 窗口未就绪,2 秒后重试(启动画面期)
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ PDDLogInstall(); });
            return;
        }
        gLogInstalled = YES;

        static dispatch_once_t once;
        dispatch_once(&once, ^{ gLogTarget = [PDDLogTarget new]; });

        if (!gLogTab) {
            UIView *tab = [[UIView alloc] initWithFrame:CGRectMake(win.bounds.size.width - 84,
                                                                    win.bounds.size.height - 120, 64, 30)];
            tab.tag = kLogTabTag;
            tab.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.55];
            tab.layer.cornerRadius = 15;
            UILabel *lb = [[UILabel alloc] initWithFrame:tab.bounds];
            lb.text = @"日志";
            lb.font = [UIFont boldSystemFontOfSize:12];
            lb.textColor = [UIColor whiteColor];
            lb.textAlignment = NSTextAlignmentCenter;
            [tab addSubview:lb];
            tab.userInteractionEnabled = YES;
            UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:gLogTarget
                                                                                  action:@selector(pdd_tabTapped)];
            [tab addGestureRecognizer:tap];
            UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:gLogTarget
                                                                                  action:@selector(pdd_pan:)];
            [tab addGestureRecognizer:pan];
            gLogTab = tab;
        }
        [win addSubview:gLogTab];

        if (PDDCfgBool(cfg, @"autoShowLog", YES)) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                PDDLogExpand();
                PDDLog(@"[日志] 已自动展开日志面板(autoShowLog=true,点按钮可收起)");
            });
        }
    });
}

@interface PDDCapture : NSObject
+ (void)runFromVC:(UIViewController *)vc trigger:(NSString *)trigger force:(BOOL)force;
@end

@implementation PDDCapture

+ (void)runFromVC:(UIViewController *)vc trigger:(NSString *)trigger force:(BOOL)force {
    if (!vc) return;
    NSDictionary *cfg = PDDConfig();
    if (!force && !PDDCfgBool(cfg, @"autoCapture", YES)) return;
    // 手动强制模式:放宽 detailOnly,列表页卡片数据也能抓
    if (force) {
        NSMutableDictionary *loose = [cfg mutableCopy];
        loose[@"detailOnly"] = @NO;
        cfg = loose;
    }

    dispatch_async(gScanQueue, ^{
        NSMutableSet *v = [NSMutableSet set];
        NSMutableArray *hits = [NSMutableArray array];
        int budget = (int)PDDCfgInt(cfg, @"budget", 4000);
        PDDScan(vc, cfg, (int)PDDCfgInt(cfg, @"maxDepth", 4), v, hits, &budget);
        if (hits.count == 0) {
            if (force) PDDToast(@"PDD 未识别到商品数据(可先探测字段)");
            PDDLog(@"[%@] 未识别到商品数据(0 命中)%@", trigger,
                   force ? @"" : @" -- 可能键名漂移,详见 docs/PROBE.md");
            return;
        }
        // 优先选"最像详情商品主体"的节点:含 skus 优先,其次键数多
        NSDictionary *best = hits[0];
        NSUInteger bestScore = 0;
        for (NSDictionary *hit in hits) {
            NSUInteger score = hit.count;
            if (hit[@"skus"] || PDDContainsAnyCand(hit, PDDCands(cfg, @"sku"))) score += 1000;
            if (PDDContainsAnyCand(hit, PDDCands(cfg, @"goodsId"))) score += 100;
            if (score > bestScore) { bestScore = score; best = hit; }
        }

        NSString *gid = PDDStr(PDDValueForCands(best, PDDCands(cfg, @"goodsId")));
        PDDLog(@"[%@] 命中 %lu 个候选,选用 goodsID=%@,页面 %@",
               trigger, (unsigned long)hits.count,
               gid.length ? gid : @"(未知)", NSStringFromClass([vc class]));
        // 组装 H5 同构容器并落盘(文件名=商品ID.txt)
        NSDictionary *payload = PDDBuildPayload(cfg, best);
        PDDWrite(cfg, payload, gid);
    });
}

@end

#pragma mark - 手动兜底(截屏)

static void PDDHandleScreenshot(NSNotification *note) {
    NSDictionary *cfg = PDDConfig();
    if (!PDDCfgBool(cfg, @"screenshotTrigger", YES)) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = PDDTopVC();
        if (top) {
            [PDDCapture runFromVC:top trigger:@"manual" force:YES];
        }
    });
}

static UIViewController *PDDTopVC(void) {
    UIWindow *win = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if ([s isKindOfClass:UIWindowScene.class]) {
            UIWindowScene *ws = (UIWindowScene *)s;
            win = ws.windows.firstObject;
            if (win) break;
        }
    }
    if (!win) win = UIApplication.sharedApplication.windows.firstObject;
    UIViewController *vc = win.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    if ([vc isKindOfClass:UINavigationController.class]) {
        vc = ((UINavigationController *)vc).topViewController;
    }
    return vc;
}

#pragma mark - Logos Hooks

%ctor {
    PDDConfig(); // 预热配置 + 队列
    PDDLog(@"插件 v%@ 注入成功,静默模式:截屏一次=抓取一次当前页面", kPluginVer);

    // 延迟安装日志面板(App 启动画面过后主窗口就绪)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        PDDLogInstall();
    });

    // 首次运行生成可编辑 config.json 模板(若目录不存在则创建)
    dispatch_async(gScanQueue, ^{
        NSError *err = nil;
        [[NSFileManager defaultManager] createDirectoryAtPath:kDumpDir
                                 withIntermediateDirectories:YES attributes:nil error:&err];
        if (![[NSFileManager defaultManager] fileExistsAtPath:kCfgPath]) {
            NSDictionary *d = PDDDefaultConfig();
            NSMutableDictionary *plain = [d mutableCopy];
            [plain removeObjectForKey:@"skipPrefixes"]; // 注释字段仅作参考,过滤表保留内置
            [plain removeObjectForKey:@"skipClasses"];
            plain[@"lastPluginVer"] = kPluginVer;
            NSData *j = [NSJSONSerialization dataWithJSONObject:plain
                                                        options:NSJSONWritingPrettyPrinted
                                                          error:nil];
            [j writeToFile:kCfgPath atomically:YES];
        }
    });
    if (PDDCfgBool(PDDConfig(), @"screenshotTrigger", YES)) {
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationUserDidTakeScreenshotNotification
                                                          object:nil queue:nil
                                                      usingBlock:^(NSNotification *n) {
            PDDHandleScreenshot(n);
        }];
    }
}

%hook UIViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;

    NSDictionary *cfg = PDDConfig();
    if (!PDDCfgBool(cfg, @"autoCapture", YES)) return;
    // 同一 VC 实例只自动触发一次(再次 push 进详情页是新实例,会再次触发)
    if (objc_getAssociatedObject(self, &kAutoDoneKey)) return;
    objc_setAssociatedObject(self, &kAutoDoneKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // 快速预检通过后才进入完整扫描,避免列表/其他页面空转
    dispatch_async(gScanQueue, ^{
        if (!PDDQuickProbe(cfg, self)) return;
        double delay = [[cfg objectForKey:@"captureDelaySec"] doubleValue];
        if (delay <= 0) delay = 1.5;
        PDDLog(@"[自动] 页面 %@ 出现商品数据特征,%.1fs 后抓取",
               NSStringFromClass([self class]), delay);
        // 后台再等数据加载完成,然后全量扫描抓取
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                       gScanQueue, ^{
            [PDDCapture runFromVC:self trigger:@"auto" force:NO];
        });
    });
}

%end
