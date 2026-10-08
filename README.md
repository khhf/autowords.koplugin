# AutoWords —— 按字数自动翻页的 KOReader 插件

**结论先说：你的需求完全可以实现，插件已经写好并通过测试。**
唯一的坑是"取当前页文字"的接口选择——KOReader 里那个看起来最顺手的 `document:getPageText()`
对 EPUB/FB2/TXT 这类 crengine 文档**会直接报错**（详见下文"技术可行性"）。正确做法是
`document:getTextFromPositions()`，插件用的就是它。

```
autowords.koplugin/
├── _meta.lua              # 插件元信息（名称、描述）
├── main.lua               # 插件主体：计时、翻页、菜单、对话框
├── autowords_count.lua    # 纯 Lua 的 UTF-8 字数/词数统计（无依赖）
└── autowords_i18n.lua     # 界面文本（中文表 + 其它语言交给 KOReader 翻译）
```

---

## 1. 它做什么

KOReader 自带的 AutoTurn 是"每隔固定秒数翻一页"。问题很明显：一页只有两行字和一页
密密麻麻的文字，用同一个秒数必然有一边不合适。

AutoWords 改成**按字数计时**：

```
本页停留时间 = 本页可见文字数 ÷ 阅读速度（字/分钟） × 60 秒
```

而"阅读速度"可以直接**用你正在看的这一页来校准**——设置界面里始终显示当前页有多少字，
以及按当前速度会停留多少秒。这就是你说的"显示当前页面有多少文字，以便用户校准自己的阅读速度"。

### 使用流程

1. 打开一本书，在阅读界面点顶部菜单 → **导航** → **AutoWords**
2. 对话框顶部会显示，例如：

   ```
   本页：486 字
   阅读速度：300 字/分钟
   → AutoWords 在此页停留 97.2 秒
   ```

3. 点 **以本页校准**，输入"我读完这一页需要多少秒"，比如 80 秒，
   插件反推出速度 = 486 ÷ 80 × 60 ≈ 365 字/分钟并保存。
4. 点 **开始**，之后每翻到一页，插件都会重新统计该页字数并按新字数计时。
5. 再点一次 **停止** 即关闭。

### 设置项

| 菜单项 | 说明 | 默认 |
| --- | --- | --- |
| 阅读速度 | 每分钟读多少字/词，10–3000 | 300 |
| 以本页校准 | 用当前页 + 你输入的秒数反推速度 | — |
| 计数方式 | **字数**（每个非空白 UTF-8 字符算 1，中文直觉）／**词数**（中文逐字、西文按单词） | 字数 |
| 最短停留 | 任何页面至少停留这么久（图片页很有用） | 2 秒 |
| 最长停留 | 停留上限，0 = 不限制 | 不限 |
| 触摸后重新计时 | 你触摸屏幕（手动翻页、划词…）后，本页倒计时重新开始 | 开 |
| 翻页距离 | 每次翻多少屏，1 = 一整屏（滚动模式下可设小数） | 1 |

界面语言跟随 KOReader 的界面语言：中文界面显示中文，其余语言显示英文
（`autowords_i18n.lua` 里就是那张中文对照表，想改成别的语言照抄一份即可）。

还可以把 **开始/停止** 和 **设置** 绑到手势或快捷键：手势 → 动作列表里搜 `AutoWords`
（插件通过 `Dispatcher:registerAction` 注册了 `autowords_toggle` / `autowords_settings`）。

---

## 2. 安装

把整个 `autowords.koplugin` 目录（不是里面的文件）复制到 KOReader 的 `plugins/` 目录：

| 平台 | 路径 |
| --- | --- |
| Kindle | `/mnt/us/koreader/plugins/` |
| Kobo | `.kobo/koreader/plugins/`（KFMon 安装为 `.adds/koreader/plugins/`） |
| PocketBook | `applications/koreader/plugins/` |
| Android | `/sdcard/koreader/plugins/` |
| Linux/macOS | KOReader 安装目录下的 `plugins/` |

然后**完全重启 KOReader**（不是返回书架），插件即被加载。
如果重启后没出现，去 菜单 → 插件管理 确认 AutoWords 是启用状态。

不需要任何编译，纯 Lua。

---

## 3. 技术可行性（源码级结论）

针对你问的"能不能拿到当前页面有多少文字的接口"，我把 KOReader master 源码拉下来逐条核对过：

**① `document:getPageText(pageno)` 不能用（关键坑）**

`frontend/document/document.lua` 里的抽象实现是：

```lua
function Document:getPageText(pageno)
    -- is this worth caching? not done yet.
    local page = self._document:openPage(pageno)
    local text = page:getPageText()
    page:close()
    return text
end
```

但 `CreDocument._document` 是 crengine 的 userdata，它的方法表里**既没有 `openPage` 也没有
`getPageText`**（`koreader-base/ffi/cre.cpp` 的 `credocument_meth` 全表可查），
所以 `CreDocument:getPageText()` 会抛 `attempt to call a nil value (method 'openPage')`。
全仓库也没有任何调用者——它是给 MuPDF 后端准备的，而且 PDF 那边返回的是结构化表而不是字符串。
**所以"直接取整页文本"这条路在 EPUB 上是死的。**

**② 正确接口：`CreDocument:getTextFromPositions(pos0, pos1, do_not_draw_selection)`**

```lua
-- frontend/document/credocument.lua
function CreDocument:getTextFromPositions(pos0, pos1, do_not_draw_selection)
    ...
    local text_range = self._document:getTextFromPositions(pos0.x, pos0.y, pos1.x, pos1.y,
        drawSelection, drawSegmentedSelection)
    if text_range then
        local line_boxes = self:getScreenBoxesFromPositions(text_range.pos0, text_range.pos1, true)
        return { text = text_range.text, pos0 = ..., pos1 = ..., sboxes = line_boxes }
    end
end
```

传 `{x=0,y=0}` 到 `{x=Screen:getWidth(), y=Screen:getHeight()}`、第三个参数 `true`
（不画选区高亮），就能拿到**当前屏幕上这段文字**，然后自己数字数。
KOReader 自己的状态栏"本页行数/字数"就是这么实现的
（`ReaderView:getCurrentPageLineWordCounts()`，`readerview.lua:1466`）。

返回 `nil`（图片页、坐标落在非文本节点上）或空串都可能出现，插件对两种情况都做了处理。

**③ 其它可能的路**

- 整页（含屏幕外）文本：`document:getPageXPointer(page)` 取本页起点 + 下一页起点，
  再 `getTextFromXPointers(xp0, xp1)`。页号是 1-based。**插件没用这条路**，因为
  自动翻页关心的是"读者接下来要读的这屏文字"，可见区域才是准确的口径（双页模式下
  是左右两页之和）。
- `getStatistics()` 返回的是文档级统计字符串，字段含义未公开保证，不能当页字数用。
- `pagemap` 的 `chars_per_synthetic_page` 只是"合成页每页多少字符"的设置值，不是实际字数。

**④ 性能**

- `getTextFromPositions` 的结果**不进 crengine 的调用缓存**（它在 `setupCallCache` 里被标记为
  `add_buffer_trash`），也就是说每次都是一次真实开销。所以插件**每次翻页只调用一次**，
  并带一层以"页号 + 滚动位置"为键的缓存。
- **没有任何轮询**：不是"每 100ms 检查一次"，而是"算出本页该停多久 → 定一个定时器 → 到点翻页"。
  空闲时 CPU 开销为零。
- 除文本提取外只有一遍线性字符扫描（`autowords_count.lua`，O(n)，不建中间表）。
- 计时用 `UIManager:scheduleIn` / `unschedule`（和官方 AutoTurn 同一套），
  并用 `PluginShare.pause_auto_suspend` 阻止阅读期间自动休眠（该标志由
  `plugins/autosuspend.koplugin` 消费）。

**⑤ PDF / DJVU**

按你的要求不做支持，而且是**显式拒绝**而不是静默失效：插件通过
`ui.paging` / `document.info.has_pages` 判断文档类型，固定版式文档会在尝试启用时提示
"只支持可重排格式"并自动关掉。

---

## 4. 比你原本设想更好的地方（以及为什么）

你原本的思路是：设定一个"基准页字数 → 基准秒数"，再按 `当前页字数 ÷ 基准页字数 × 基准秒数`
做一个比例换算。这个公式和我用的 `字数 ÷ 速度 × 60` 在数学上**完全等价**——
区别只在"用户要输入什么"：

- 你的口径要求用户先找到一个"标准页"，输入它的字数，再输入读它要几秒（两次输入，且要挑页面）；
- 插件的口径只有一个内部量（速度，字/分钟），而它**可以自动从当前页反推**：
  你在设置里选"以本页校准"，看一眼当前页字数（界面直接显示），输入"这页我读了 N 秒"，
  速度就出来了。之后无论页面多密多疏，换算都自动完成。

换句话说：**基准页是不必要的中间变量**，把它消掉之后精度一样，但用户的动作少一半，
而且换书、换字号、换排版之后都不需要重新挑基准页（每次翻页都是按当页实际字数重算的）。

另外几个刻意的设计选择：

- **按可见区域而不是整页统计**：滚动模式下"页"的概念会漂移，
  用屏幕可见文字数才是"我接下来要读多少字"的准确答案；
- **每次翻页都重算，而不是全书算一次**：改字号、改页边距、换排版后无需任何额外操作；
- **事件驱动重新计时**：手动翻页（`PageUpdate` / `PosUpdate` 事件）会立刻按新页字数重置倒计时，
  不会出现"手动翻过去还要干等半分钟"的情况；
- **到文末自动停**：翻页没有产生位移时（连续两次确认，或收到 crengine 的 `EndOfBook` 事件）
  自动停用，而不是无限空转（`EndOfBook` 时不再自己弹窗，让官方 ReaderStatus 的"书末"提示照常出现）。

---

## 5. 已知限制

1. **不支持 PDF / DJVU / 图片型文档**（按需求设计）。
2. 文本统计的是**屏幕可见区域**：双页模式下是两页之和；页眉页脚、页码如果属于正文流也会被计入。
3. `getTextFromPositions` 在极少数情形（图片页、刚打开文档还没排版完）返回 `nil`，
   此时按 0 字处理 → 使用"最短停留"时间，不会卡死。
4. 弹出菜单、字典、对话框时**不会翻页**，会每 2 秒重试，关掉弹窗后自动恢复。
5. 速度单位是"字/分钟"，需要一次校准才能贴合你的实际速度；默认 300 字/分钟对中文大致偏慢，
   建议用"以本页校准"定一次。
6. KOReader 的界面字符串需要 `.po` 目录文件，用户侧插件无法挂接，
   所以中文是插件自带的小型对照表实现的（跟随界面语言）。

---

## 6. 开发与测试

`tests/` 下有一套**离线单元测试**：用纯 Lua（不需要设备、不需要 KOReader）加载真实的
`autowords_count.lua` 和 `main.lua`，用 stub 顶替 KOReader 模块，验证：

- UTF-8 计数：中英混排、空白（含全角空格 U+3000、不换行空格 U+00A0）、标点、空串、`nil`
- 延迟计算：600 字 @300 字/分 = 120 秒；上限/下限钳制；速度为 0 的兜底
- 固定版式文档被拒绝、图片页计 0、引擎抛错被 `pcall` 拦住
- 调度：只允许一个待触发的定时器、翻页事件与距离、nextTick 之后再排下一次
- 到文末：连续两次无位移 → 停用；`EndOfBook` 事件路径同样停用；
  弹窗遮挡时只重试不翻页；触摸后重新计时；禁用时取消定时器、启用时持久化
- `init()`：设置读取、菜单注册、`InputEvent` 钩子注册、定时任务创建
- 生命周期：`onReaderReady` / `onSuspend` / `onResume` / `onCloseDocument` / `onCloseWidget`
- 界面冒烟：菜单项与**全部 7 个对话框**（含每一个按钮回调、SpinWidget 回调）都能正常构造执行，
  不支持 PDF 时也能正常提示而不崩
- 中文本地化：译文正确、占位符保留、未翻译串回退英文

运行（需要 `pip install lupa`，仅用于跑测试，插件本身不依赖它）：

```
python tests/run_tests.py
```

当前结果：**156 checks, 0 failures / ALL TESTS PASSED**。

改动 `main.lua` 后建议至少跑一次测试，能挡住绝大多数"上了设备才发现"的低级错误

（这类插件在设备上没有交互式调试器，日志是唯一线索，所以离线测试很值）。

工作目录里的 `_research/` 是调研期间下载的 KOReader master 源码与调研笔记

（`koreader-自动翻页插件调研.md`），仅供查阅，不影响插件运行，可以整个删掉。

 ## 7. 其他说明

 本人并非开发，不会太会使用github，插件和github的发布均为使用deepseek辅助制作和照步骤发布出来的，如果有人需要修改请自行拿取
