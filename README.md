# 越狱插件 PddDump — 拼多多商品数据截屏抓取

在拼多多 App 里,**每截屏一次,抓一次当前页面的商品数据**,存成**与网页端采集同构的
TXT 文件**(内容为 JSON),按**当日日期文件夹**存放,**文件名 = 商品ID**。拉回电脑可
直接丢进现有 pdd_extract 工具链批量解析成 Excel。默认全静默:打开 App 不自动运行、不打扰浏览。

| 项目 | 说明 |
|---|---|
| 适用设备 | 已越狱 iPhone,iOS 15–16,**rootless**(Dopamine / palera1n rootless) |
| 目标应用 | 拼多多(App 名 `Pinduoduo`,Bundle: com.xunmeng.pinduoduo) |
| 触发方式 | **纯手动(v0.3.0 默认全静默)**:拼多多在前台时,**截屏一次 = 抓一次当前页面**;打开 App 不自动运行(想要自动抓,config.json 把 `autoCapture` 改 `true` 并重开 App) |
| 保存路径 | `/var/mobile/Documents/PddDump/yyyy-MM-dd/`(如 `.../PddDump/2026-09-05/`) |
| 命名规则 | `{商品ID}.txt`;同一天重复进入同一商品 → **覆盖**,保留最新快照 |
| 文件内容 | `{"store":{"initDataObj":{"goods":{...},"mall":{...}}}}` 单行紧凑 JSON(与网页端一致) |
| 与现有流程衔接 | 把 txt 拷进 pdd_extract 的 `input/` 目录即可批量解析出 Excel |
| 运行日志 | 右下角「日志」悬浮按钮手动点开查看(默认**不自动弹出**);日志写入 `PddDump/log.txt` |

示例文件 `2026-09-05/1688888888888.txt` 内容(简化展示,实际单行且含全部原始键):

```json
{"store":{"initDataObj":{"goods":{
  "goodsID":"1688888888888","goodsName":"某商品标题","sideSalesTip":"已拼 10 万+件",
  "minGroupPrice":19.9,"maxGroupPrice":29.9,"mallID":123456,
  "skus":[{"skuId":..., "specs":[...], "groupPrice":19.9, "quantity":1000, "isOnsale":1}],
  "...此处保留该商品在 App 内存中的其余全部字段(原键名)":""
},"mall":{"mallID":123456,"mallName":"某旗舰店"}}}}
```

> 手机端从 App 内存抓取,字段集是网页端 `store.initDataObj.goods` 的**子集 + 原键名**;
> 关键字段(goodsID / goodsName / skus / 价格 / 店铺)已补齐为网页端标准键名,
> 其余字段保留 App 原始键名,不影响解析工具使用。

---

## 一、前置清单

- [ ] 越狱设备一台(iOS 15–16 rootless),已装 Filza(没有就去 Sileo 装)
- [ ] 一个 GitHub 账号(云编译用;不需要 Mac) — 或一台装了 Theos 的 Mac
- [ ] 拼多多 App 已登录,能正常打开商品详情页

## 二、编译出 .deb

### 方法 A:GitHub Actions 云编译(推荐,不需要 Mac)

1. GitHub 新建一个 **私有仓库**,名字随意(如 `pdd-dump-tweak`)。
2. 把 `PddDumpTweak` 文件夹里的**全部内容**(含隐藏的 `.github`)推到该仓库:

   ```bash
   cd PddDumpTweak
   git init && git add . && git commit -m "init" && git branch -M main
   git remote add origin https://github.com/<你的账号>/<仓库名>.git
   git push -u origin main
   ```

   > 不会命令行的:直接到 github.com 网页点 Upload files 上传也行(需把 `.github` 一起传)。
3. 仓库页面 → **Actions** 标签 → 左侧 **Build PddDump** → 右侧 **Run workflow** → 绿色按钮。
4. 等约 5–10 分钟(首次下载 iOS SDK 约 1GB)。跑完后进该次运行记录,底部 **Artifacts** → 下载 `PddDump-deb`,解压得到 `PddDump_0.3.0-1_iphoneos-arm64.deb`。

### 方法 B:本地 Mac(已装 Theos)

```bash
export THEOS=/opt/theos        # 你的 theos 路径
export THEOS_PACKAGE_SCHEME=rootless
make clean package FINALPACKAGE=1
# 产物: packages/PddDump_0.3.0-1_iphoneos-arm64.deb
```

## 三、安装(约 1 分钟)

1. 把 `.deb` 传到手机(微信文件助手 / AirDrop / 数据线都行),用 **Filza** 打开。
2. Filza 弹窗点 **安装**,等提示完成。
3. **后台杀掉拼多多再重新打开**(不是注销手机,杀 App 即可)。

## 四、使用(v0.3.0 起:纯手动截屏触发)

1. 打开拼多多(插件**不自动运行**,页面正常浏览,无打扰)。
2. 在任意页面(**详情页 / 列表 / 首页都行**),直接**截屏**(电源+音量上)。
   - 每次截屏 = 抓一次当前页面的商品数据。
   - 屏幕底部出现黑色横幅「PDD 已保存 2026-09-05/1688888888888.txt」= 成功;
     再次截同一商品 = 覆盖更新当天那份文件。
   - 没看到横幅 = 当前页面没识别到商品节点,见「六、排障」。
3. 想回看插件干了什么:点屏幕右下角**「日志」**按钮(可拖动),面板实时显示每次截屏的抓取过程。

> 截屏抓取对当前页面做全量扫描,优先取「最像商品主体」的节点(含 skus/商品ID 的数据块),
> 所以列表页截图也会存下当前列表里的商品卡片数据;详情页截图则存完整详情。
> 想恢复「进详情页自动抓」:config.json 里 `autoCapture` 改 `true`,杀拼多多重开。

### 运行日志(排障可视化)

**默认不自动弹出**(全静默)。需要时点右下角**「日志」**悬浮按钮,面板实时滚动显示插件运行过程:

```
21:40:01 | 插件 v0.3.0 注入成功,静默模式:截屏一次=抓取一次当前页面
21:45:20 | [manual] 命中 3 个候选,选用 goodsID=1688888888888,页面 PDDGoodsDetailViewController
21:45:21 | [保存] 已覆盖写入 2026-09-05/1688888888888.txt (312.4 KB)
```

> 想恢复「打开 App 自动弹出日志」:config.json 里 `autoShowLog` 改 `true`,杀拼多多重开。

| 操作 | 效果 |
|---|---|
| 点面板右上角「×」 | 收起面板(右下角悬浮「日志」按钮仍在) |
| 点右下角「日志」按钮 | 展开 / 收起面板(面板开着时也能点按钮收起) |
| 拖动「日志」按钮 | 可移到屏幕任意边缘,不挡浏览 |
| 看历史日志 | `/var/mobile/Documents/PddDump/log.txt`(超过 512KB 自动截断,可用 Filza 打开/导出) |

日志每行内容对应运行阶段,照「六、排障」对照即可定位问题:
- 每次截屏后出现 `[manual] 命中 …` → 抓取链路正常,再看下一行「保存」
- `[manual] 未识别到商品数据(0 命中)` → 当前页面没有可识别的商品节点(键名漂移或页面无商品),改 config.json
- 「保存」行 → 已落盘,含路径与文件大小;没有该行 = 上一步失败原因在日志里

## 五、把文件拿到电脑

三种方式任选,按你顺手的来:

| 方式 | 操作 |
|---|---|
| Filza | `/var/mobile/Documents/PddDump/<日期>/` → 长按文件 → 分享 → 微信/AirDrop 发到电脑 |
| 爱思助手 / 3uTools | 数据线连电脑 → 「文件管理」→ 路径同上 → 导出整个日期文件夹(适合批量) |
| SFTP | 设备开 OpenSSH(需另装)后电脑执行 `sftp root@<设备IP>`(rootless 默认密码 alpine) |

拿到电脑后,**直接把这些 .txt 丢进现有 pdd_extract 工具的 `input/` 目录**,
运行导出脚本即可出 Excel(内容结构与网页端采集完全同构,无需任何转换)。

## 六、排障

| 现象 | 原因与处理 |
|---|---|
| 打开 App 没有「日志」按钮 | config.json `logPanel` 被设为 false;或拼多多被系统剥离注入、插件完全没跑(先看 `/var/mobile/Documents/PddDump/log.txt` 有没有「注入成功」,没有则查 Dopamine 插件启用状态) |
| 装了没任何反应 | 杀拼多多重开;确认 Dopamine 里已信任/启用本插件;确认拼多多版本未被系统剥离注入 |
| 打开拼多多闪退/提示越狱 | 拼多多存在越狱检测,先装屏蔽插件(如 Shadow/Hestia,Source 里搜)再测试;或换备用机 |
| 截屏后无横幅、无文件 | 商品字段键名随版本变了。确认 `/var/mobile/Documents/PddDump/<日期>/` 下没有文件;按 `docs/PROBE.md` 探测真实键名后补进 config.json。也可点「日志」看「0 命中」提示 |
| 有文件但关键字段缺失(如无 skus / 店铺) | 编辑 `/var/mobile/Documents/PddDump/config.json`,把真实键名补进对应候选数组 → 杀拼多多重开(免重编译)。也可先用 Filza 打开 txt 看里面的**实际键名**,照抄进候选表 |
| 截屏抓的是列表卡片而不是当前详情 | 截屏为"抓当前页可识别商品",详情页有 sku 数据会优先取详情主体;首页/列表页无详情数据时取页面第一个商品卡片是预期行为。想要整页商品列表建议停在详情页截屏 |
| 想恢复自动抓取 | config.json `autoCapture` 改 `true` → 杀拼多多重开(进详情页自动抓,同商品当日覆盖) |

## 七、调优(config.json,免重编译)

首次运行自动在 `/var/mobile/Documents/PddDump/config.json` 生成模板,用 Filza 文本编辑,
改完**杀拼多多重开**生效。常用项:

```jsonc
{
  "autoCapture": false,      // 自动抓取开关(默认关=纯截屏手动;改 true 恢复自动)
  "screenshotTrigger": true, // 截屏触发:每次截屏抓一次当前页面
  "detailOnly": true,        // 详情特征优先(含 sku/店铺),降低误抓
  "banner": true,            // 保存横幅提示
  "logPanel": true,          // 运行日志总开关(关掉连悬浮按钮都没有)
  "autoShowLog": false,      // 启动 App 自动弹出日志面板(默认关,点「日志」按钮才看)
  "logFileMaxKB": 512,       // log.txt 自动截断阈值
  "captureDelaySec": 1.5,    // (自动模式用)进页面后延迟
  "goodsId": ["goodsId", "goodsID", "goods_id"],  // ← 探测到新键名就加到这里
  "name":    ["goodsName", "goods_name"],
  "price":   ["minGroupPrice", "price", "groupPrice"],
  "sales":   ["salesTip", "sideSalesTip"],
  "mallIdKeys":    ["mallId", "mall_id", "mallID"],   // 店铺ID候选
  "mallNameKeys":  ["mallName", "mall_name"],         // 店铺名候选
  "sku":     ["skus", "skuList", "sku"]
}
```

> 补充说明:文件内容是「商品主体的全部原始键 + 已补齐的网页端标准键(goodsID / goodsName /
> sideSalesTip / minGroupPrice / maxGroupPrice / skus 元素补 specs)」。
> 哪些字段缺失,直接看 txt 里的实际键名,抄进对应候选表即可,免重编译。

完整默认候选表见 `PDDConfig.h`;字段级探测教程见 `docs/PROBE.md`。

## 八、风险与合规

- **越狱检测**:拼多多对越狱设备有检测,可能闪退/功能受限 —— 本插件不绕过也不保证能共存,
  若被检测需自行配合屏蔽类插件,或仅在备用机使用。
- **版本漂移**:拼多多每个版本都可能改内部字段名。对策:①文件即原始数据,字段缺失不影响已抓内容;
  ②config.json 免重编译补键名;③按 `docs/PROBE.md` 探测。大版本更新后建议先验证一轮。
- **性能**:扫描在后台队列进行,带对象预算上限,实测体感无卡顿;理论上仍请以真机为准。
- **合规**:仅限**本人设备、本人账号**浏览行为下的数据采集,用于选品研究;
  不得抓取他人隐私信息,不得用于任何侵权/违法用途。
- **未实机验证声明**:本工程在 Windows 环境编写,**未经真机编译与运行验证**。
  首次安装务必用备用越狱机测试;编译若报错,优先核对 SDK 下载链接与 Theos 版本。

## 九、文件结构

```
PddDumpTweak/
├── Tweak.x                  # 插件主逻辑(扫描/判定/落盘/触发)
├── PDDConfig.h              # 默认配置 + 字段候选键表
├── Makefile                 # Theos 构建(rootless)
├── control                  # deb 包描述
├── .github/workflows/build.yml  # GitHub Actions 云编译
└── docs/PROBE.md            # 字段探测指南(版本漂移时用)
```
