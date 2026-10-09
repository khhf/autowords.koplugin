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
