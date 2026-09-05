//
//  PDDConfig.h
//  拼多多商品数据抓取插件 - 字段候选表与默认配置
//
//  说明:
//  1. 拼多多各版本的商品详情数据模型键名可能变化(如 goodsId -> goods_id)。
//  2. 本文件提供"默认候选键表",抓取时会按候选表逐项匹配。
//  3. 设备上首次运行会在 /var/mobile/Documents/PddDump/config.json 生成一份
//     可编辑配置;用户可用 Filza 修改 config.json 后杀掉拼多多重开,即可生效,
//     无需重新编译。config.json 的字段结构与此处一致。
//

#ifndef PDDConfig_h
#define PDDConfig_h

#import <Foundation/Foundation.h>

/// 默认配置 + 候选键表。规范键(normKey) -> 候选原始键数组。
/// 候选键越全,越能在不同 App 版本下命中。
static NSDictionary *PDDDefaultConfig(void) {
    static NSDictionary *c = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        c = @{
            // ---------- 行为开关 ----------
            // v0.3.0 起默认全静默:打开 App 不自动抓、不自动弹面板
            // 抓取 = 手动:每截屏一次,抓一次当前页面的商品数据
            @"autoCapture"     : @NO,    // 自动抓取(进详情页自动抓)。想恢复自动改 true
            @"screenshotTrigger": @YES,  // 截屏手动触发:每次截屏抓一次当前页面
            @"detailOnly"      : @YES,   // 仅当数据含 sku 或店铺字段才落盘(详情页特征,降低列表页误抓)
            @"banner"          : @YES,   // 保存成功后屏幕横幅提示
            @"logPanel"        : @YES,   // 运行日志:右下角「日志」悬浮按钮(总开关)
            @"autoShowLog"     : @NO,    // App 启动后自动弹出日志面板(默认静默,点按钮才看)
            @"captureDelaySec" : @1.5,   // 页面出现后延迟抓取(等数据加载完,自动模式用)
            @"budget"          : @4000,  // 单次全量扫描访问对象上限
            @"quickBudget"     : @400,   // 快速预检访问上限
            @"maxDepth"        : @4,     // 递归深度上限

            // ---------- 商品 id 强校验 ----------
            // 拼多多商品 id 为数字串;正则: ^\d{6,24}$
            @"goodsIdRegex"    : @"^[0-9]{6,24}$",

            // ---------- 日志 ----------
            @"logFileMaxKB"    : @512,   // log.txt 超过此大小自动截断(保留最近日志)

            // ---------- 字段候选键表 ----------
            @"goodsId": @[@"goodsId", @"goodsID", @"goods_id", @"goodsIdStr", @"goodsIdString", @"goodsIDStr"],
            @"name"   : @[@"goodsName", @"goods_name", @"name", @"goodsNameEx", @"goodsNameExt", @"goodsTitle"],
            @"price"  : @[@"minGroupPrice", @"maxGroupPrice", @"minOnSaleGroupPrice", @"groupPrice",
                          @"minPrice", @"price", @"salePrice", @"marketPrice", @"lowPrice", @"highPrice",
                          @"minNormalPrice", @"maxNormalPrice"],
            @"sales"  : @[@"salesTip", @"salesText", @"sales", @"soldQuantity", @"soldNum", @"salesNum",
                          @"goodsSales", @"salesTipEx", @"soldCount", @"sideSalesTip"],
            @"mall"   : @[@"mallName", @"mall_name", @"mallNickname", @"mallId", @"mall_id", @"mallID"],
            @"mallIdKeys" : @[@"mallId", @"mall_id", @"mallID", @"mallIDStr", @"mallIdStr"],
            @"mallNameKeys" : @[@"mallName", @"mall_name", @"mallNickname"],
            @"thumb"  : @[@"thumbUrl", @"thumb_url", @"goodsImageUrl", @"goods_image_url",
                          @"hdThumbUrl", @"hd_thumb_url", @"mainImageUrl", @"topBannerImage"],
            @"sku"    : @[@"sku", @"skus", @"skuList", @"sku_list", @"skuInfo"],

            // 跳过扫描的系统框架类名前缀 / 精确类名,避免误入 UI 视图树与底层对象
            @"skipPrefixes": @[@"UI", @"CA", @"WK", @"CG", @"AV", @"_UI", @"NSConcrete", @"__NS", @"JS"],
            @"skipClasses" : @[@"NSInvocation", @"NSMethodSignature", @"NSCFTimer", @"__NSCFTimer",
                               @"NSBlock", @"__NSMallocBlock__", @"NSFileManager", @"NSUserDefaults",
                               @"NSProcessInfo", @"NSBundle", @"NSXPCConnection"]
        };
    });
    return c;
}

#endif /* PDDConfig_h */
