-- ============================================================================
-- view/px/Core.lua — pixelfx core 的 Lua 移植子集（PoC）
--
-- 原版是 ESM：src/core/{color,math,painter,fx}.js。这里只搬「纯色 + 抖动」这条线，
-- 没搬 sprite/text/mask/poly/arc/beam（用不到的先不写，需要时按原文件补）。
--
-- 颜色打包保持和原版一致：0xAABBGGRR（内存里正好是 R,G,B,A），
-- 所以可以直接塞 Image:SetPixelInt，引擎会按 RGBA 逐字节写进去。
-- 注意 Lua 里 0 是真值，原版所有 `if (!c)` 都要写成 `c == 0`。
-- ============================================================================

local Core = {}

-- 像素字（mini / big）。Painter:text / measure 用它，其余地方不需要直接碰。
Core.Font = require "tap-pixelfx.core.Font"

local floor, ceil, sqrt, atan, abs, min, max = math.floor, math.ceil, math.sqrt, math.atan, math.abs, math.min, math.max

Core.TAU = math.pi * 2

function Core.clamp(v, lo, hi)
    if v < (lo or 0) then
        return lo or 0
    end
    if v > (hi or 1) then
        return hi or 1
    end
    return v
end

local function i8(v)
    -- JS 的 `& 255` 对浮点是「截断后取低 8 位」，负数补回 0..255
    return floor(v) & 0xFF
end

function Core.rgb(r, g, b)
    return (0xFF << 24) | (i8(b) << 16) | (i8(g) << 8) | i8(r)
end

function Core.red(c)
    return c & 0xFF
end

function Core.green(c)
    return (c >> 8) & 0xFF
end

function Core.blue(c)
    return (c >> 16) & 0xFF
end

function Core.alpha(c)
    return (c >> 24) & 0xFF
end

--- "#rgb" / "#rrggbb" / 数字 -> 颜色数
function Core.hex(h)
    if type(h) == "number" then
        return h
    end
    local s = h:gsub("#", "")
    if #s == 3 then
        s = s:sub(1, 1) .. s:sub(1, 1) .. s:sub(2, 2) .. s:sub(2, 2) .. s:sub(3, 3) .. s:sub(3, 3)
    end
    local v = tonumber(s:sub(1, 6), 16)
    return Core.rgb((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF)
end

function Core.toHex(c)
    return string.format("#%02x%02x%02x", Core.red(c), Core.green(c), Core.blue(c))
end

--- 两色线性插值
function Core.mix(a, b, t)
    t = Core.clamp(t, 0, 1)
    return Core.rgb(
        Core.red(a) + (Core.red(b) - Core.red(a)) * t,
        Core.green(a) + (Core.green(b) - Core.green(a)) * t,
        Core.blue(a) + (Core.blue(b) - Core.blue(a)) * t
    )
end

function Core.scale(c, k)
    return Core.rgb(min(255, Core.red(c) * k), min(255, Core.green(c) * k), min(255, Core.blue(c) * k))
end

function Core.luma(c)
    return (0.299 * Core.red(c) + 0.587 * Core.green(c) + 0.114 * Core.blue(c)) / 255
end

--- ramp 重采样到 n 阶（首尾不动）
function Core.fit(r, n)
    local out = {}
    for i = 1, #r do
        out[i] = Core.hex(r[i])
    end
    if #out == n then
        return out
    end
    local res = {}
    for i = 0, n - 1 do
        res[i + 1] = out[floor(i * (#out - 1) / max(1, n - 1) + 0.5) + 1]
    end
    return res
end

function Core.at(r, t)
    local i = Core.clamp(floor(t * #r), 0, #r - 1)
    return r[i + 1]
end

--- hex 列表 -> 颜色数列表
---@param list any[]
---@return number[]
function Core.ramp(list)
    local out = {}
    for i = 1, #list do
        out[i] = Core.hex(list[i])
    end
    return out
end

--- 沿色带取插值色（光晕用；像素本体用 Core.at 直接挑台阶）
function Core.blend(r, t)
    local x = Core.clamp(t, 0, 1) * (#r - 1)
    local i = math.min(#r - 2, floor(x))
    if i < 1 then
        i = 1
        if #r < 2 then
            return r[1]
        end
    end
    return Core.mix(r[i], r[i + 1], x - i)
end

-- 带色相偏移的色带（暗到亮）。特效的 palette 选项可以直接用这些名字取，
-- 于是同一份代码换个名字就换一套配色。
Core.PAL = {
    fire = { "#1f0b10", "#4a1118", "#8c1d1c", "#cc3a1a", "#f2701f", "#ffae35", "#ffe27a", "#fff8d6" },
    ember = { "#1a0a0e", "#3d1012", "#701a14", "#a8301a", "#e0561e", "#ff8a2a", "#ffc46a" },
    lava = { "#14060a", "#380a10", "#6e1210", "#ac2410", "#e8501a", "#ff8c2a", "#ffd25a" },
    smoke = { "#0e0c12", "#1d1a22", "#2e2a35", "#433e4b", "#5c5664", "#7b7484", "#a39cab" },
    dust = { "#1c1610", "#33281c", "#4f3f2c", "#6e5a40", "#927a58", "#b89f78", "#dcc8a2" },
    ice = { "#0c1430", "#162c5c", "#1f4f94", "#2f7fcc", "#58b4ec", "#9bdcff", "#d8f4ff", "#ffffff" },
    water = { "#081830", "#0e2e5a", "#14508c", "#1c76bc", "#36a2e0", "#78ccf4", "#c4ecff", "#ffffff" },
    electric = { "#0a0f2e", "#172a78", "#2550d0", "#3f8cff", "#7cc8ff", "#c8f0ff", "#ffffff" },
    volt = { "#24160a", "#5e3a0c", "#a8680f", "#e8a218", "#ffd23c", "#fff08a", "#ffffff" },
    poison = { "#0d1a0c", "#173a14", "#265e18", "#3f8a1e", "#6cb82a", "#a8e04a", "#e0ff8a" },
    holy = { "#2a1c08", "#5a3e10", "#9a6c18", "#d8a428", "#ffd84a", "#fff09a", "#fffbe6", "#ffffff" },
    heal = { "#08201a", "#0f3f2c", "#17663e", "#24924e", "#3ec466", "#7ee88a", "#c8ffc4", "#ffffff" },
    arcane = { "#140a26", "#2b1252", "#481c88", "#6b2cc0", "#9a48ec", "#c684ff", "#ecc8ff", "#ffffff" },
    shadow = { "#050308", "#0f0a18", "#1c1230", "#2c1a4a", "#432468", "#5e3290", "#8048b8", "#a970e0" },
    blood = { "#14040a", "#3a0a14", "#6a101c", "#a01824", "#d42a30", "#ff5a50", "#ff9a8a" },
    earth = { "#140e0a", "#2a1e14", "#47321e", "#69492a", "#8e6638", "#b88a52", "#dcb47c" },
    stone = { "#0e0e12", "#1c1c24", "#2c2c38", "#42424f", "#5c5c6b", "#7d7d8c", "#a4a4b2", "#d0d0da" },
    gold = { "#1e1206", "#4a2c08", "#86520c", "#c48412", "#f0b424", "#ffe066", "#fff6c4", "#ffffff" },
    leaf = { "#0c1a0e", "#163418", "#225224", "#357530", "#4f9a3a", "#7cc048", "#b4e070", "#e4ffb0" },
    wood = { "#160c06", "#2e1a0c", "#4a2c14", "#6a421e", "#8e5c2c", "#b47c40", "#d8a464" },
    metal = { "#0c0e14", "#1c2230", "#2e3648", "#4a5468", "#6e7a90", "#9aa6ba", "#d0d8e6", "#ffffff" },
    bone = { "#1a1814", "#3a352c", "#5e5648", "#8a806c", "#b8ad96", "#e4dcc8", "#fffaf0" },
    neon = { "#1a0516", "#3d0a33", "#701560", "#b0228f", "#f53cd1", "#ff86e6", "#ffd2f6", "#ffffff" },
    cyber = { "#041418", "#08303a", "#0c5260", "#108088", "#18b4b0", "#4ce8d8", "#b4fff0", "#ffffff" },
    matrix = { "#020a04", "#05200c", "#0a3c16", "#106624", "#1a9a34", "#3cd650", "#a4ffa8", "#e8ffe8" },
    candy = { "#ff4a5a", "#ff9a2a", "#ffe03c", "#5ad84a", "#3cc8ff", "#7a6cff", "#f53cd1" },
    night = { "#07060d", "#0c0a18", "#131026", "#1b1734", "#241f44", "#2f2956" },
}

--- Core.PAL 的同一批色带，已经转成颜色数
Core.RAMP = {}
for k, v in pairs(Core.PAL) do
    Core.RAMP[k] = Core.ramp(v)
end

--- 按名字或直接给色带取 palette（特效的 opts.palette 可以是 "ice" 也可以是色值列表）
---@param pal any
---@return any
function Core.paletteOf(pal)
    if type(pal) == "string" then
        return Core.PAL[pal] or Core.PAL.fire
    end
    return pal
end

-- ---------------------------------------------------------------------------
-- 帧：w x h 像素，(ox, oy) 是左上角在世界里的位置。color 不透明像素，light 加色辉光。
-- 原版用 Uint32Array；Lua 这边用 table（PoC 规模下 24x24 完全够，真接游戏再看要不要换）
-- ---------------------------------------------------------------------------
function Core.createFrame(w, h, ox, oy)
    local color, light = {}, {}
    for i = 0, w * h - 1 do
        color[i] = 0
        light[i] = 0
    end
    return { w = w, h = h, ox = ox or 0, oy = oy or 0, color = color, light = light }
end

function Core.clearFrame(f)
    for i = 0, f.w * f.h - 1 do
        f.color[i] = 0
        f.light[i] = 0
    end
    return f
end

-- 4x4 Bayer 阈值：alpha 超过本格的阈值才画
local BAYER = {}
do
    local raw = { 0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5 }
    for i = 1, 16 do
        BAYER[i] = (raw[i] + 0.5) / 16
    end
end

local Painter = {}
Painter.__index = Painter

function Core.newPainter(frame)
    return setmetatable({ frame = frame }, Painter):reset()
end

function Painter:reset()
    local f = self.frame
    self.w, self.h = f.w, f.h
    self.ox, self.oy = f.ox, f.oy
    self.C, self.L = f.color, f.light
    self.tx, self.ty, self.fx, self.cs, self.sn = 0, 0, 1, 1, 0
    self.fade, self.lightK = 1, 1
    self.layer = "front"
    return self
end

--- 把特效原点放到 (x, y)，flip 镜像，angle 旋转
function Painter:place(x, y, flip, angle)
    self.tx, self.ty = x, y
    self.fx = flip and -1 or 1
    angle = angle or 0
    self.cs, self.sn = math.cos(angle), math.sin(angle)
    return self
end

function Painter:toX(x, y)
    return self.tx + x * self.fx * self.cs - y * self.sn
end

function Painter:toY(x, y)
    return self.ty + x * self.fx * self.sn + y * self.cs
end

function Painter:fromX(sx, sy)
    local dx, dy = sx - self.tx, sy - self.ty
    return (dx * self.cs + dy * self.sn) * self.fx
end

function Painter:fromY(sx, sy)
    local dx, dy = sx - self.tx, sy - self.ty
    return -dx * self.sn + dy * self.cs
end

function Painter:cellX(x, y)
    return floor(self:toX(floor(x) + 0.5, floor(y) + 0.5))
end

function Painter:cellY(x, y)
    return floor(self:toY(floor(x) + 0.5, floor(y) + 0.5))
end

--- 屏幕空间整像素写：颜色 0 表示「什么都不画」，不会擦掉已有像素
function Painter:put(sx, sy, c, a)
    if c == nil or c == 0 then
        return
    end
    a = (a or 1) * self.fade
    if a < 1 and a <= BAYER[((sy & 3) << 2 | (sx & 3)) + 1] then
        return
    end
    local x, y = sx - self.ox, sy - self.oy
    if x < 0 or y < 0 or x >= self.w or y >= self.h then
        return
    end
    self.C[y * self.w + x] = c
end

--- 加色写进 light 缓冲
function Painter:add(sx, sy, c, k)
    k = (k or 1) * self.fade * self.lightK
    if k <= 0.004 then
        return
    end
    local x, y = sx - self.ox, sy - self.oy
    if x < 0 or y < 0 or x >= self.w or y >= self.h then
        return
    end
    local i = y * self.w + x
    local d = self.L[i]
    -- 直接拆字节，不走 Core.red/green/blue —— 每个光晕像素都要过一次，函数调用开销比算术还贵
    local r = (d & 0xFF) + (c & 0xFF) * k
    local g = ((d >> 8) & 0xFF) + ((c >> 8) & 0xFF) * k
    local b = ((d >> 16) & 0xFF) + ((c >> 16) & 0xFF) * k
    if r > 255 then r = 255 end
    if g > 255 then g = 255 end
    if b > 255 then b = 255 end
    self.L[i] = (0xFF << 24) | ((floor(b) & 0xFF) << 16) | ((floor(g) & 0xFF) << 8) | (floor(r) & 0xFF)
end

--- 半透明叠色（烟、雾）
function Painter:blendPx(sx, sy, c, a)
    a = (a or 1) * self.fade
    if c == nil or c == 0 or a <= 0.004 then
        return
    end
    local x, y = sx - self.ox, sy - self.oy
    if x < 0 or y < 0 or x >= self.w or y >= self.h then
        return
    end
    local i = y * self.w + x
    local d = self.C[i]
    local da = ((d >> 24) & 0xFF) / 255
    local oa = a + da * (1 - a)
    local k = a / oa
    local k2 = 1 - k
    -- 不在这里建闭包：半透效果每帧要写几千个像素，Lua 里每次分配闭包会把成本翻倍
    local r = floor((c & 0xFF) * k + (d & 0xFF) * k2) & 0xFF
    local g = floor(((c >> 8) & 0xFF) * k + ((d >> 8) & 0xFF) * k2) & 0xFF
    local b = floor(((c >> 16) & 0xFF) * k + ((d >> 16) & 0xFF) * k2) & 0xFF
    self.C[i] = (floor(oa * 255) & 0xFF) << 24 | b << 16 | g << 8 | r
end

function Painter:blend(x, y, c, a)
    self:blendPx(self:cellX(x, y), self:cellY(x, y), c, a)
end

function Painter:get(x, y)
    local sx = self:cellX(x, y) - self.ox
    local sy = self:cellY(x, y) - self.oy
    if sx < 0 or sy < 0 or sx >= self.w or sy >= self.h then
        return 0
    end
    return self.C[sy * self.w + sx]
end

function Painter:px(x, y, c)
    self:put(self:cellX(x, y), self:cellY(x, y), c, 1)
end

--- 一个像素，alpha 用有序抖动衰减（硬边像素淡出）
function Painter:dot(x, y, c, a)
    if (a or 1) > 0 then
        self:put(self:cellX(x, y), self:cellY(x, y), c, a or 1)
    end
end

function Painter:light(x, y, c, k)
    self:add(self:cellX(x, y), self:cellY(x, y), c, k or 1)
end

local clamp = Core.clamp

--- 颜色/alpha 参数可以是数字，也可以是函数（形状自己的坐标）
local function call(v, a, b)
    if type(v) == "function" then
        return v(a, b)
    end
    return v
end

Core.call = call

--- 1px 直线（c / a 可以是 u 的函数：0 起点，1 终点）
function Painter:line(x0, y0, x1, y1, c, a)
    a = a or 1
    local sx, sy = self:cellX(x0, y0), self:cellY(x0, y0)
    local ex, ey = self:cellX(x1, y1), self:cellY(x1, y1)
    local dx, dy = abs(ex - sx), -abs(ey - sy)
    local stepx = (sx < ex) and 1 or -1
    local stepy = (sy < ey) and 1 or -1
    local n = max(dx, -dy)
    if n == 0 then
        n = 1
    end
    local fc, fa = type(c) == "function", type(a) == "function"
    local err, i = dx + dy, 0
    while true do
        local u = i / n
        i = i + 1
        self:put(sx, sy, fc and c(u) or c, fa and a(u) or a)
        if sx == ex and sy == ey then
            break
        end
        local e2 = 2 * err
        if e2 >= dy then
            err = err + dy
            sx = sx + stepx
        end
        if e2 <= dx then
            err = err + dx
            sy = sy + stepy
        end
    end
end

--- 实心凸多边形（偶奇规则扫描；顶点顺时针或逆时针都行）
---@param pts table { {x,y}, ... }
---@param c number
---@param a number|nil
function Painter:poly(pts, c, a)
    a = a or 1
    if #pts < 3 then
        return
    end
    local minX, maxX, minY, maxY = math.huge, -math.huge, math.huge, -math.huge
    for _, q in ipairs(pts) do
        minX = math.min(minX, q[1])
        maxX = math.max(maxX, q[1])
        minY = math.min(minY, q[2])
        maxY = math.max(maxY, q[2])
    end
    for y = math.floor(minY), math.ceil(maxY) do
        local cy = y + 0.5
        for x = math.floor(minX), math.ceil(maxX) do
            local px, py = x + 0.5, cy
            local inside = false
            local j = #pts
            for i = 1, #pts do
                local xi, yi = pts[i][1], pts[i][2]
                local xj, yj = pts[j][1], pts[j][2]
                if ((yi > py) ~= (yj > py)) and (px < (xj - xi) * (py - yi) / (yj - yi) + xi) then
                    inside = not inside
                end
                j = i
            end
            if inside then
                self:put(self:cellX(x, y), self:cellY(x, y), c, a)
            end
        end
    end
end

--- 折线
function Painter:polyline(pts, c, a)
    for i = 2, #pts do
        self:line(pts[i - 1][1], pts[i - 1][2], pts[i][1], pts[i][2], c, a)
    end
end

--- 半透明圆盘（烟、汽、尘）：c / a 可以是 (d, ang) 的函数
function Painter:disc(cx, cy, r, c, a)
    if r < 0.5 then
        return self:blend(cx, cy, call(c, 0, 0), call(a, 0, 0))
    end
    self:each(cx - r, cy - r, cx + r, cy + r, function(x, y, sx, sy)
        local dx, dy = x - cx, y - cy
        local d2 = dx * dx + dy * dy
        if d2 > r * r then
            return
        end
        local d = sqrt(d2) / r
        local ang = atan(dy, dx)
        self:blendPx(sx, sy, call(c, d, ang), call(a, d, ang))
    end)
end

--- 圆环：半径 r - w 到 r 之间（c / a 可以是 (v, ang) 的函数，v = 0 内沿 → 1 外沿）
function Painter:ring(cx, cy, r, w, c, a)
    a = a or 1
    local r0 = max(0, r - w)
    local span = r - r0
    if span == 0 then
        span = 1
    end
    self:shade(cx - r, cy - r, cx + r, cy + r, function(x, y, o)
        local dx, dy = x - cx, y - cy
        local d2 = dx * dx + dy * dy
        if d2 > r * r or d2 < r0 * r0 then
            return 0
        end
        local v = (w > 0) and ((sqrt(d2) - r0) / span) or 1
        local ang = atan(dy, dx)
        o.c = call(c, v, ang)
        o.a = call(a, v, ang)
    end)
end

--- 实心圆
function Painter:circle(cx, cy, r, c, a)
    a = a or 1
    if r < 0.6 then
        return self:dot(cx, cy, call(c, 0, 0), call(a, 0, 0))
    end
    self:shade(cx - r, cy - r, cx + r, cy + r, function(x, y, o)
        local dx, dy = x - cx, y - cy
        local d2 = dx * dx + dy * dy
        if d2 > r * r then
            return 0
        end
        local d = sqrt(d2) / r
        local ang = atan(dy, dx)
        o.c = call(c, d, ang)
        o.a = call(a, d, ang)
    end)
end

--- 椭圆
function Painter:ellipse(cx, cy, rx, ry, c, a)
    a = a or 1
    if rx <= 0 or ry <= 0 then
        return
    end
    self:shade(cx - rx, cy - ry, cx + rx, cy + ry, function(x, y, o)
        local dx, dy = (x - cx) / rx, (y - cy) / ry
        local d2 = dx * dx + dy * dy
        if d2 > 1 then
            return 0
        end
        local d = sqrt(d2)
        local ang = atan(dy, dx)
        o.c = call(c, d, ang)
        o.a = call(a, d, ang)
    end)
end

--- 字符串小图：rows 是字符行，pal 把字符映射成颜色（"." / " " 表示空）
--- opts: { scale, a, flip（左右镜像）, flipY（上下翻转）, tint（全部用同一个颜色） }
function Painter:sprite(rows, pal, x, y, opts)
    opts = opts or {}
    local k = opts.scale or 1
    local a = opts.a or 1
    local W = #rows[1]
    local cache = {}
    for r = 1, #rows do
        local line = rows[r]
        for q = 1, #line do
            local ch = line:sub(q, q)
            if ch ~= "." and ch ~= " " then
                local c = opts.tint
                if c == nil then
                    c = cache[ch]
                    if c == nil then
                        local v = pal[ch]
                        c = (v == nil) and 0 or Core.hex(v)
                        cache[ch] = c
                    end
                end
                if c ~= 0 then
                    local col = opts.flip and (W - q) or (q - 1)
                    local row = opts.flipY and (#rows - r) or (r - 1)
                    if k == 1 then
                        self:dot(x + col, y + row, c, a)
                    else
                        self:rect(x + col * k, y + row * k, k, k, c, a)
                    end
                end
            end
        end
    end
end

--- 沿线段的柔光（光束）
function Painter:glowLine(x0, y0, x1, y1, r, c, k)
    k = k or 0.5
    if r < 1 or k <= 0.004 then
        return
    end
    local ax, ay = self:toX(x0, y0), self:toY(x0, y0)
    local bx, by = self:toX(x1, y1), self:toY(x1, y1)
    local dx, dy = bx - ax, by - ay
    local L2 = dx * dx + dy * dy
    if L2 == 0 then
        L2 = 1e-9
    end
    for sy = floor(min(ay, by) - r), ceil(max(ay, by) + r) do
        for sx = floor(min(ax, bx) - r), ceil(max(ax, bx) + r) do
            local px, py = sx + 0.5, sy + 0.5
            local u = clamp(((px - ax) * dx + (py - ay) * dy) / L2, 0, 1)
            local ex, ey = ax + dx * u - px, ay + dy * u - py
            local d = sqrt(ex * ex + ey * ey) / r
            if d < 1 then
                local f = 1 - d
                self:add(sx, sy, c, f * f * k)
            end
        end
    end
end

--- 包住一个圆的柔光（冲击波的光）：半径 R 上下 width 内衰减
function Painter:glowRing(x, y, R, r, c, k)
    k = k or 0.5
    if r < 1 or k <= 0.004 then
        return
    end
    local cx, cy = self:toX(x, y), self:toY(x, y)
    local E = R + r
    for sy = floor(cy - E), math.ceil(cy + E) do
        for sx = floor(cx - E), math.ceil(cx + E) do
            local ex, ey = sx + 0.5 - cx, sy + 0.5 - cy
            local d = abs(sqrt(ex * ex + ey * ey) - R) / r
            if d < 1 then
                local f = 1 - d
                self:add(sx, sy, c, f * f * k)
            end
        end
    end
end

--- 圆环上的一段（刀光、扫过的弧）：半径 r - w 到 r、角度 a0 → a1
--- c / a 可以是 (u, v) 的函数（u：0 在 a0 → 1 在 a1；v：0 内沿 → 1 外沿）
--- w 可以是 u 的函数，用来做两端收尖的月牙
function Painter:arc(cx, cy, r, w, a0, a1, c, a)
    a = a or 1
    local span = a1 - a0
    local wf = type(w) == "function"
    self:shade(cx - r, cy - r, cx + r, cy + r, function(x, y, o)
        local dx, dy = x - cx, y - cy
        local d = sqrt(dx * dx + dy * dy)
        if d > r then
            return
        end
        local ang = atan(dy, dx) - a0
        ang = ang - floor(ang / (math.pi * 2)) * math.pi * 2
        if ang > span then
            return
        end
        local u = ang / span
        local ww = wf and w(u) or w
        if ww <= 0 or d < r - ww then
            return
        end
        local v = (d - (r - ww)) / ww
        o.c = call(c, u, v)
        o.a = call(a, u, v)
    end)
end

--- 粗线段（圆头）：c / a 可以是 (u 沿线, v 横向 0 中心 → 1 边缘) 的函数
function Painter:beam(x0, y0, x1, y1, width, c, a)
    a = a or 1
    local r = width / 2
    local dx, dy = x1 - x0, y1 - y0
    local L2 = dx * dx + dy * dy
    if L2 == 0 then
        L2 = 1e-9
    end
    self:shade(min(x0, x1) - r, min(y0, y1) - r, max(x0, x1) + r, max(y0, y1) + r, function(x, y, o)
        local u = clamp(((x - x0) * dx + (y - y0) * dy) / L2, 0, 1)
        local ex, ey = x0 + dx * u - x, y0 + dy * u - y
        local d2 = ex * ex + ey * ey
        if d2 > r * r then
            return
        end
        local v = sqrt(d2) / r
        o.c = call(c, u, v)
        o.a = call(a, u, v)
    end)
end

--- 三角形
function Painter:tri(x0, y0, x1, y1, x2, y2, c, a)
    self:poly({ { x0, y0 }, { x1, y1 }, { x2, y2 } }, c, a)
end

--- 像素字。opts: { font = "mini" | "big", scale, align = "left"|"center"|"right",
---   outline（描边色）, shadow（投影色）, a }
function Painter:text(str, x, y, c, opts)
    opts = opts or {}
    local Font = Core.Font
    local kind = opts.font or "mini"
    local k = opts.scale or 1
    local a = opts.a or 1
    local w = Font.textWidth(str, kind) * k
    local align = opts.align
    local left = floor(x + 0.5)
    if align == "center" then
        left = floor(x - w / 2 + 0.5)
    elseif align == "right" then
        left = floor(x - w + 0.5)
    end
    local top = floor(y + 0.5)
    local ol, sh = opts.outline, opts.shadow
    if ol ~= nil then
        Font.rasterText(str, kind, function(gx, gy)
            self:rect(left + gx * k - 1, top + gy * k - 1, k + 2, k + 2, ol, a)
        end)
    end
    if sh ~= nil then
        Font.rasterText(str, kind, function(gx, gy)
            self:rect(left + gx * k + 1, top + gy * k + 1, k, k, sh, a)
        end)
    end
    Font.rasterText(str, kind, function(gx, gy)
        self:rect(left + gx * k, top + gy * k, k, k, call(c, gx, gy), a)
    end)
end

--- 文字尺寸 [w, h]（像素）
---@return number w, number h
function Painter:measure(str, opts)
    opts = opts or {}
    local k = opts.scale or 1
    local kind = opts.font or "mini"
    return Core.Font.textWidth(str, kind) * k, Core.Font.FONTS[kind].h * k
end

--- 用遮罩填色：m = { w, h, data（1-based，w*h） }，左上角在 (x, y)
--- c / a 可以是 (mx, my) 的函数
function Painter:mask(m, x, y, c, a)
    a = a or 1
    for my = 0, m.h - 1 do
        local base = my * m.w
        for mx = 0, m.w - 1 do
            if m.data[base + mx + 1] then
                self:dot(x + mx, y + my, call(c, mx, my), call(a, mx, my))
            end
        end
    end
end

--- 遮罩外的 1px 描边
function Painter:outline(m, x, y, c, a)
    a = a or 1
    local function at(mx, my)
        return mx >= 0 and my >= 0 and mx < m.w and my < m.h and m.data[my * m.w + mx + 1]
    end
    for my = -1, m.h do
        for mx = -1, m.w do
            if not at(mx, my) and (at(mx - 1, my) or at(mx + 1, my) or at(mx, my - 1) or at(mx, my + 1)) then
                self:dot(x + mx, y + my, call(c, mx, my), call(a, mx, my))
            end
        end
    end
end

--- 遍历屏幕像素中心落在局部盒里的每一格：fn(lx, ly, sx, sy)
function Painter:each(x0, y0, x1, y1, fn)
    local ax, bx, ay, by = math.huge, -math.huge, math.huge, -math.huge
    for k = 0, 3 do
        local x = (k & 1) ~= 0 and x1 or x0
        local y = (k & 2) ~= 0 and y1 or y0
        local sx, sy = self:toX(x, y), self:toY(x, y)
        if sx < ax then ax = sx end
        if sx > bx then bx = sx end
        if sy < ay then ay = sy end
        if sy > by then by = sy end
    end
    local sx0 = max(floor(ax), self.ox)
    local sx1 = min(math.ceil(bx), self.ox + self.w - 1)
    local sy0 = max(floor(ay), self.oy)
    local sy1 = min(math.ceil(by), self.oy + self.h - 1)
    for sy = sy0, sy1 do
        for sx = sx0, sx1 do
            local cx, cy = sx + 0.5, sy + 0.5
            fn(self:fromX(cx, cy), self:fromY(cx, cy), sx, sy)
        end
    end
end

--- 逐像素着色器：fn(x, y, o) 返回颜色，或写 o.c / o.a / o.l / o.k
---
--- 这里把 each 的扫描边界和像素循环**内联**了一份：每个特效的每个形状都走这条路，
--- 中间多一层 each 的闭包调用等于每像素多两次 Lua 调用（实测占烘焙时间的一大块）。
--- 画面结果与 each 版本逐像素相同，只是少了两层函数调用。
function Painter:shade(x0, y0, x1, y1, fn)
    local o = { c = 0, a = 1, l = 0, k = 0 }
    local tx, ty, fx, cs, sn, ox, oy, w, h = self.tx, self.ty, self.fx, self.cs, self.sn, self.ox, self.oy,
        self.w, self.h

    -- 局部盒四角 → 屏幕包围盒（和 each 完全一致）
    local ax, bx, ay, by = math.huge, -math.huge, math.huge, -math.huge
    local sx1 = tx + x0 * fx * cs - y0 * sn
    local sy1 = ty + x0 * fx * sn + y0 * cs
    local sx2 = tx + x1 * fx * cs - y0 * sn
    local sy2 = ty + x1 * fx * sn + y0 * cs
    local sx3 = tx + x0 * fx * cs - y1 * sn
    local sy3 = ty + x0 * fx * sn + y1 * cs
    local sx4 = tx + x1 * fx * cs - y1 * sn
    local sy4 = ty + x1 * fx * sn + y1 * cs
    ax = math.min(sx1, sx2, sx3, sx4)
    bx = math.max(sx1, sx2, sx3, sx4)
    ay = math.min(sy1, sy2, sy3, sy4)
    by = math.max(sy1, sy2, sy3, sy4)

    local px0 = math.max(floor(ax), ox)
    local px1 = math.min(math.ceil(bx), ox + w - 1)
    local py0 = math.max(floor(ay), oy)
    local py1 = math.min(math.ceil(by), oy + h - 1)

    for sy = py0, py1 do
        local cy = sy + 0.5 - ty
        for sx = px0, px1 do
            local cx = sx + 0.5 - tx
            local lx = (cx * cs + cy * sn) * fx
            local ly = -cx * sn + cy * cs
            o.c, o.a, o.l, o.k = 0, 1, 0, 0
            local c = fn(lx, ly, o)
            if c == nil or c == false then
                c = o.c
            end
            if c ~= 0 then
                self:put(sx, sy, c, o.a)
            end
            if o.k > 0 then
                self:add(sx, sy, (o.l ~= 0) and o.l or c, o.k)
            end
        end
    end
end

function Painter:rect(x, y, w, h, c, a)
    if self.sn == 0 then
        local x0, y0 = floor(x + 0.5), floor(y + 0.5)
        local x1, y1 = floor(x + w + 0.5), floor(y + h + 0.5)
        for yy = y0, y1 - 1 do
            for xx = x0, x1 - 1 do
                self:put(self:cellX(xx, yy), self:cellY(xx, yy), c, a or 1)
            end
        end
        return
    end
    self:shade(x, y, x + w, y + h, function(lx, ly, o)
        if lx < x or ly < y or lx >= x + w or ly >= y + h then
            return 0
        end
        o.c, o.a = c, a or 1
    end)
end

--- 径向辉光进 light 缓冲
function Painter:glow(x, y, r, c, k)
    k = k or 0.5
    if r < 1 or k <= 0.004 then
        return
    end
    local cx, cy = self:toX(x, y), self:toY(x, y)
    for sy = floor(cy - r), math.ceil(cy + r) do
        local dy = (sy + 0.5 - cy) / r
        for sx = floor(cx - r), math.ceil(cx + r) do
            local dx = (sx + 0.5 - cx) / r
            local d = dx * dx + dy * dy
            if d < 1 then
                local f = 1 - sqrt(d)
                self:add(sx, sy, c, f * f * k)
            end
        end
    end
end

Core.Painter = Painter
Core.WHITE = Core.hex("#ffffff")
Core.BLACK = Core.hex("#000000")
Core.INK = Core.hex("#0b0a10")
Core.BAYER = BAYER

--- 模拟 JS 的 Uint8ClampedArray 写入：0..255 夹紧 + 四舍六入五取偶
local function u8(v)
    if v ~= v then
        return 0
    end
    if v <= 0 then
        return 0
    end
    if v >= 255 then
        return 255
    end
    local f = floor(v)
    local d = v - f
    if d > 0.5 then
        return f + 1
    elseif d < 0.5 then
        return f
    end
    return (f % 2 == 0) and f or f + 1
end

Core.u8 = u8

--- color + light 合成为 RGBA 字节（bg = nil 表示透明底）
--- 可选传矩形 (x0, y0, x1, y1) 只合成有内容的那块：空区域是纯开销
---
--- 热路径：这里每个像素要做 4 次颜色变换 + 4 次「夹紧并四舍六入五取偶」。
--- 所以字节拆解和取整全部内联，不调 Core.red/u8 —— 每像素省下 8 次 Lua 调用，
--- 合成耗时大约减半。结果与调用版本逐字节相同。
function Core.composite(f, out, bg, rx0, ry0, rx1, ry1)
    rx0 = rx0 or 0
    ry0 = ry0 or 0
    rx1 = rx1 or (f.w - 1)
    ry1 = ry1 or (f.h - 1)
    local w = f.w
    local color, light = f.color, f.light
    local flat = (bg ~= nil)
    local bgr, bgg, bgb = 0, 0, 0
    if flat then
        bgr, bgg, bgb = bg & 0xFF, (bg >> 8) & 0xFF, (bg >> 16) & 0xFF
    end

    for py = ry0, ry1 do
        local base = py * w
        for px = rx0, rx1 do
            local i = base + px
            local c = color[i]
            local l = light[i] & 0xFFFFFF
            local r, g, b, a
            local ca = (c >> 24) & 0xFF
            local cr, cg, cb = c & 0xFF, (c >> 8) & 0xFF, (c >> 16) & 0xFF
            if ca == 255 then
                r, g, b, a = cr, cg, cb, 255
            elseif not flat then
                r, g, b, a = cr, cg, cb, ca
            else
                local fr = ca / 255
                local inv = 1 - fr
                r, g, b, a = cr * fr + bgr * inv, cg * fr + bgg * inv, cb * fr + bgb * inv, 255
            end
            if l ~= 0 then
                local lr, lg, lb = l & 0xFF, (l >> 8) & 0xFF, (l >> 16) & 0xFF
                if a < 255 then
                    local pa = a / 255
                    local pr, pg, pb = r * pa + lr, g * pa + lg, b * pa + lb
                    local hi = lr
                    if lg > hi then hi = lg end
                    if lb > hi then hi = lb end
                    local na = hi / 255
                    if pa > na then na = pa end
                    if na > 1 then na = 1 end
                    if na > 0 then
                        r, g, b, a = pr / na, pg / na, pb / na, na * 255
                        if r > 255 then r = 255 end
                        if g > 255 then g = 255 end
                        if b > 255 then b = 255 end
                    end
                else
                    r, g, b = r + lr, g + lg, b + lb
                    if r > 255 then r = 255 end
                    if g > 255 then g = 255 end
                    if b > 255 then b = 255 end
                end
            end
            local j = i * 4
            -- 夹紧 + 四舍六入五取偶（JS Uint8ClampedArray 的语义）
            local f8, d8
            if r <= 0 then
                out[j + 1] = 0
            elseif r >= 255 then
                out[j + 1] = 255
            else
                f8 = floor(r)
                d8 = r - f8
                if d8 > 0.5 then
                    out[j + 1] = f8 + 1
                elseif d8 < 0.5 then
                    out[j + 1] = f8
                else
                    out[j + 1] = (f8 % 2 == 0) and f8 or f8 + 1
                end
            end
            if g <= 0 then
                out[j + 2] = 0
            elseif g >= 255 then
                out[j + 2] = 255
            else
                f8 = floor(g)
                d8 = g - f8
                if d8 > 0.5 then
                    out[j + 2] = f8 + 1
                elseif d8 < 0.5 then
                    out[j + 2] = f8
                else
                    out[j + 2] = (f8 % 2 == 0) and f8 or f8 + 1
                end
            end
            if b <= 0 then
                out[j + 3] = 0
            elseif b >= 255 then
                out[j + 3] = 255
            else
                f8 = floor(b)
                d8 = b - f8
                if d8 > 0.5 then
                    out[j + 3] = f8 + 1
                elseif d8 < 0.5 then
                    out[j + 3] = f8
                else
                    out[j + 3] = (f8 % 2 == 0) and f8 or f8 + 1
                end
            end
            if a <= 0 then
                out[j + 4] = 0
            elseif a >= 255 then
                out[j + 4] = 255
            else
                f8 = floor(a)
                d8 = a - f8
                if d8 > 0.5 then
                    out[j + 4] = f8 + 1
                elseif d8 < 0.5 then
                    out[j + 4] = f8
                else
                    out[j + 4] = (f8 % 2 == 0) and f8 or f8 + 1
                end
            end
        end
    end
    return out
end

return Core
