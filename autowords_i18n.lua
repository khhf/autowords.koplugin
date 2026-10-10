--[[--
Minimal localization for AutoWords.

KOReader only loads .po catalogues from its own l10n/ directory, which a
user-side plugin cannot extend.  Since the menu strings of this plugin are a
small closed set, we keep a Chinese table right here and fall back to
KOReader's gettext() for every other language.

The keys are the exact English msgids used in main.lua (including the %1/%2
placeholders consumed by T()).
]]

local gettext = require("gettext")

local zh = {
    ["AutoWords"] = "AutoWords",

    ["words"] = "词",
    ["characters"] = "字",
    ["yes"] = "是",
    ["no"] = "否",
    ["none"] = "不限",
    ["s"] = "秒",
    ["%1 s"] = "%1 秒",

    ["AutoWords: %1 %2/min"] = "AutoWords：%1 %2/分钟",
    ["AutoWords: settings"] = "AutoWords：设置",
    ["AutoWords: start/stop"] = "AutoWords：开始/停止",

    ["Reading speed"] = "阅读速度",
    ["Calibrate on this page"] = "以本页校准",
    ["Calibrate"] = "校准",
    ["Start"] = "开始",
    ["Stop"] = "停止",
    ["More settings"] = "更多设置",
    ["Close"] = "关闭",
    ["Set"] = "确定",
    ["Cancel"] = "取消",

    ["AutoWords settings\ncounting: %1 | wait after touch: %2"] =
        "AutoWords 设置\n计数方式：%1 ｜ 触摸后重新计时：%2",
    ["Count: characters"] = "计数方式：字数",
    ["Count: words"] = "计数方式：词数",
    ["Wait after touch: on"] = "触摸后重新计时：开",
    ["Wait after touch: off"] = "触摸后重新计时：关",

    ["Minimum delay"] = "最短停留",
    ["Minimum delay: %1 s"] = "最短停留：%1 秒",
    ["Maximum delay"] = "最长停留",
    ["Maximum delay: %1"] = "最长停留：%1",
    ["Page distance"] = "翻页距离",
    ["Page distance: %1"] = "翻页距离：%1",
    ["Icon position: %1"] = "图标位置：%1",
    ["Mode: %1"] = "模式：%1",
    ["whole page"] = "整页翻页",
    ["sentence guide"] = "逐句导引",
    ["running"] = "运行中",
    ["stopped"] = "已停止",
    ["Whole page"] = "整页翻页",
    ["Sentence guide"] = "逐句导引",
    ["(experimental)"] = "（实验性）",
    ["sentence guide (experimental)"] = "逐句导引（实验性）",
    ["Experiment: the sentence guide has not been verified on a real device yet. If no line appears, please check More settings → Diagnostics."] =
        "实验功能：逐句导引尚未在真机上验证过。如果没有出现横线，请查看「更多设置 → 诊断信息」。",
    ["Sentence guide: %1"] = "逐句导引：%1",
    ["Sentence guide: %1\nThis sentence: %2 %3 → waits %4 s"] =
        "逐句导引：%1\n本句：%2 %3 → 停留 %4 秒",
    ["Reading mode\n\nWhole page: turns the page once the text on it has been read.\n\nSentence guide: draws a line under the sentence being read and moves on sentence by sentence.\n\nThe two modes are mutually exclusive.\n\n⚠ The sentence guide is experimental: its logic is covered by offline tests, but it has not yet been verified on a real device. It may do nothing or stop immediately."] =
        "阅读模式\n\n整页翻页：这一页的文字读完后翻页。\n\n逐句导引：在当前朗读的句子下面画一条横线，按句推进。\n\n两种模式互斥，只能选一个。\n\n⚠ 逐句导引是实验性功能：逻辑已由离线测试覆盖，但尚未在真机上验证过。它可能毫无反应，或者一启动就停止。",
    ["The sentence guide needs a reflowable document (EPUB, FB2, TXT ...)."] =
        "逐句导引需要可重排文档（EPUB、FB2、TXT 等）。",
    ["Min. sentence time: %1 s"] = "最短句停留：%1 秒",
    ["Punctuation pause: %1x"] = "标点停顿：%1 倍",
    ["Paragraph pause: %1 s"] = "段落停顿：%1 秒",
    ["Minimum sentence time"] = "最短句停留",
    ["A sentence stays on screen at least this long, so a page full of short dialogue lines does not race past."] =
        "一句话至少停留这么久，避免对话多的页面上横线飞快往下跑。",
    ["Punctuation pause"] = "标点停顿",
    ["Scales every pause taken at punctuation (comma, semicolon, sentence end). 1.0 is the built-in amount, 0 disables punctuation pauses."] =
        "统一缩放标点处的停顿（逗号、分号、句末）。1.0 是内置值，0 表示标点不停顿。",
    ["Paragraph pause"] = "段落停顿",
    ["Extra time when a sentence ends at the end of a paragraph."] =
        "句子正好在段落末尾结束时的额外停留。",
    ["AutoWords: next sentence"] = "AutoWords：下一句",
    ["AutoWords: previous sentence"] = "AutoWords：上一句",
    ["AutoWords: pause/resume (sentence guide)"] = "AutoWords：暂停/继续（逐句导引）",
    ["Pause"] = "暂停",
    ["Resume"] = "继续",
    ["AutoWords guide paused."] = "AutoWords 已暂停。",
    ["AutoWords guide resumed."] = "AutoWords 已继续。",
    ["AutoWords stopped: this position could not be read as a sentence."] =
        "AutoWords 已停止：这个位置读不出句子。",
    ["Follow by scrolling: on"] = "自动滚动跟随：开",
    ["Follow by scrolling: off"] = "自动滚动跟随：关",
    ["Guide scheduled: %1, paused: %2"] = "导引已排定：%1，已暂停：%2",
    ["Guide position: %1"] = "导引起点：%1",
    ["Guide stop reason: %1"] = "导引停止原因：%1",
    ["Guide last reject: %1"] = "上次取句被拒：%1",
    ["Guide steps back: %1"] = "回退步数：%1",
    ["Guide last boxes: %1"] = "上次行框数：%1",
    ["Guide current sentence: %1"] = "当前句：%1",
    ["Guide activity:"] = "导引活动记录：",
    ["top bar"] = "顶部状态栏",
    ["bottom bar"] = "底部状态栏",
    ["top + bottom"] = "顶部 + 底部",
    ["hidden"] = "不显示",
    ["Top status bar"] = "顶部状态栏",
    ["Bottom status bar"] = "底部状态栏",
    ["Top + bottom"] = "顶部 + 底部",
    ["Do not show"] = "不显示",
    ["Where to show the icon.\nThe top status bar needs KOReader's \"Alt status bar\" to be enabled first."] =
        "图标显示在哪里。\n顶部状态栏需要先在 KOReader 里启用「备用状态栏（Alt status bar）」。",
    ["Alt status bar (top): %1"] = "顶部状态栏（Alt）：%1",
    ["Alt status bar content registered: %1"] = "顶部状态栏内容已注册：%1",
    ["Icon character: %1"] = "图标字符：%1",
    ["Diagnostics"] = "诊断信息",
    ["Character shown in the status bar.\nIf it appears as an empty box, please pick another one."] =
        "状态栏上显示的字符。\n如果显示成空心方框，请换一个。",

    ["Plugin loaded: %1"] = "插件已加载：%1",
    ["Running: %1"] = "正在运行：%1",
    ["Countable document: %1"] = "可统计的文档：%1",
    ["Status bar found: %1"] = "找到状态栏：%1",
    ["Status bar visible: %1"] = "状态栏可见：%1",
    ["Status bar height: %1 px"] = "状态栏高度：%1 像素",
    ["Status bar content registered: %1"] = "状态栏内容已注册：%1",
    ["Icon characters: %1"] = "图标字符：%1",
    ["Text on this page: %1 %2"] = "本页文字：%1 %2",
    ["Status bar text: %1"] = "状态栏文本：%1",

    ["Shortest time AutoWords will ever wait on a page (useful for pages holding only an image)."] =
        "在单页上停留的最短时间（对只有图片的页面很有用）。",
    ["Longest time AutoWords will wait on a page. Set to 0 for no limit."] =
        "在单页上停留的最长时间。设为 0 表示不限制。",
    ["How far the view moves on each turn. 1 = one screen. Values below 1 only apply in scroll mode; in paged mode the move is rounded to whole pages."] =
        "每次翻页移动的距离。1 = 一整屏。小于 1 的值只在滚动模式下生效；翻页模式下会取整为整页。",

    ["This page: %1 %2\nReading speed: %3 %2/min\n→ AutoWords waits %4 s on this page"] =
        "本页：%1 %2\n阅读速度：%3 %2/分钟\n→ AutoWords 在此页停留 %4 秒",
    ["This page holds %1 %2.\nAt %3 %2 per minute AutoWords waits %4 s here."] =
        "本页共 %1 %2。\n按每分钟 %3 %2 计算，AutoWords 在此页停留 %4 秒。",
    ["This page holds %1 %2.\nHow many seconds do you need to read it?"] =
        "本页共 %1 %2。\n你读完这一页需要多少秒？",
    ["The text of this page could not be read."] = "无法读取本页文字。",
    ["Page text unavailable."] = "无法获取本页文字。",
    ["There is no countable text on this page, so it cannot be used for calibration."] =
        "本页没有可统计的文字，无法用于校准。",
    ["Reading speed set to %1 %2/min."] = "阅读速度已设为 %1 %2/分钟。",

    ["AutoWords is on: %1 %2/min.\nThis page: %3 %2 → %4 s."] =
        "AutoWords 已开启：%1 %2/分钟。\n本页：%3 %2 → %4 秒。",
    ["AutoWords stopped: the end of the document has been reached."] =
        "AutoWords 已停止：已到达文档末尾。",
    ["AutoWords only works with reflowable documents (EPUB, FB2, TXT ...), not with PDF or DJVU."] =
        "AutoWords 只支持可重排格式（EPUB、FB2、TXT 等），不支持 PDF 或 DJVU。",
    ["This document type is not supported: AutoWords needs the text layout engine (EPUB, FB2, TXT ...), so PDF and DJVU cannot be measured."] =
        "不支持此文档类型：AutoWords 需要文字排版引擎（EPUB、FB2、TXT 等），无法统计 PDF 与 DJVU 的字数。",
}

local chinese -- nil = not decided yet
local function use_chinese()
    if chinese == nil then
        local lang = G_reader_settings and G_reader_settings:readSetting("language")
        chinese = (type(lang) == "string" and lang:match("^zh") ~= nil) or false
    end
    return chinese
end

return function(msgid)
    if use_chinese() then
        local translated = zh[msgid]
        if translated then return translated end
    end
    return gettext(msgid)
end
