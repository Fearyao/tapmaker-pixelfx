-- ============================================================================
-- view/px/Grid.lua — pixelfx 的 Grid（离屏小画布）+ 两个收尾 pass
--
-- 原版：src/fx/critters/_lib.js 的 Grid / shift
--       src/fx/salvage/_props.js 的 outline / cap
-- 只搬 enemy-shot 用到的那几个方法（idx/set/get/erase/shade/draw/clear/outline）。
-- ============================================================================

local Core = require "tap-pixelfx.core.Core"

local Grid = {}
Grid.__index = Grid

local floor = math.floor

--- 局部坐标画布：格子范围 [x0, x0+w) x [y0, y0+h)，每格一个颜色 + alpha
function Grid.new(x0, y0, w, h)
    local self = setmetatable({}, Grid)
    self.x0, self.y0 = floor(x0), floor(y0)
    self.w, self.h = w, h
    self.c, self.a, self.tag = {}, {}, {}
    for i = 0, w * h - 1 do
        self.c[i] = 0
        self.a[i] = 1
        self.tag[i] = 0
    end
    self.o = { a = 1, t = 0 }
    return self
end

function Grid:idx(x, y)
    local ix, iy = floor(x) - self.x0, floor(y) - self.y0
    if ix < 0 or iy < 0 or ix >= self.w or iy >= self.h then
        return -1
    end
    return iy * self.w + ix
end

function Grid:set(x, y, c, a, tag)
    local i = self:idx(x, y)
    if i >= 0 and c ~= nil and c ~= 0 then
        self.c[i] = c
        self.a[i] = a or 1
        self.tag[i] = tag or 0
    end
end

function Grid:get(x, y)
    local i = self:idx(x, y)
    if i < 0 then
        return 0
    end
    return self.c[i]
end

function Grid:tagAt(x, y)
    local i = self:idx(x, y)
    if i < 0 then
        return 0
    end
    return self.tag[i]
end

function Grid:erase(x, y)
    local i = self:idx(x, y)
    if i >= 0 then
        self.c[i] = 0
    end
end

--- 盒内逐格调用 fn(x + 0.5, y + 0.5, out)；返回非 0 颜色才写，可写 out.a / out.t
function Grid:shade(x0, y0, x1, y1, fn)
    local o = self.o
    for y = floor(y0), floor(y1) do
        for x = floor(x0), floor(x1) do
            o.a, o.t = 1, 0
            local c = fn(x + 0.5, y + 0.5, o)
            if c ~= nil and c ~= 0 then
                self:set(x, y, c, o.a, o.t)
            end
        end
    end
end

--- 把网格画到 painter 上，按 (dx, dy) 平移；不透明格子走 dot（抖动淡出），半透明走 blend
function Grid:draw(p, fade, dx, dy)
    fade = fade or 1
    local X = self.x0 + floor((dx or 0) + 0.5)
    local Y = self.y0 + floor((dy or 0) + 0.5)
    for y = 0, self.h - 1 do
        for x = 0, self.w - 1 do
            local i = y * self.w + x
            local c = self.c[i]
            if c ~= 0 then
                local a = self.a[i]
                if a >= 0.999 then
                    p:dot(X + x, Y + y, c, fade)
                else
                    p:blend(X + x, Y + y, c, a * fade)
                end
            end
        end
    end
end

function Grid:clear()
    for i = 0, self.w * self.h - 1 do
        self.c[i] = 0
        self.tag[i] = 0
    end
    return self
end

--- 1px 闭合描边：空白格四邻有实心就描
function Grid:outline(c, a)
    local w, h = self.w, self.h
    local src = {}
    for i = 0, w * h - 1 do
        src[i] = self.c[i]
    end
    for y = 0, h - 1 do
        for x = 0, w - 1 do
            local i = y * w + x
            if src[i] == 0 then
                local l = x > 0 and src[i - 1] or 0
                local r = x < w - 1 and src[i + 1] or 0
                local u = y > 0 and src[i - w] or 0
                local d = y < h - 1 and src[i + w] or 0
                if l ~= 0 or r ~= 0 or u ~= 0 or d ~= 0 then
                    if c ~= 0 then
                        self.c[i] = c
                        self.a[i] = a or 1
                        self.tag[i] = 255
                    end
                end
            end
        end
    end
end

--- 循环相位：seed != 1 时从环的不同位置开始
local function wrap(x, d)
    return ((x % d) + d) % d
end

function Grid.shift(t, d, seed)
    return wrap(t + ((seed or 1) - 1) * 0.618 * d, d)
end

--- 每张道具图收尾都要的 1px 暖黑描边
local INKC = Core.hex("#14181F")

function Grid.outlineAll(g)
    g:outline(INKC)
end

--- 亮度封顶：把超过 maxY 的像素整体压下来（防止特效比甲板还亮）
function Grid.cap(g, maxY)
    maxY = maxY or 196
    local c = g.c
    for i = 0, g.w * g.h - 1 do
        local v = c[i]
        if v ~= 0 then
            local r, gr, b = Core.red(v), Core.green(v), Core.blue(v)
            local y = 0.299 * r + 0.587 * gr + 0.114 * b
            if y > maxY then
                c[i] = Core.rgb(
                    floor(r * maxY / y + 0.5),
                    floor(gr * maxY / y + 0.5),
                    floor(b * maxY / y + 0.5)
                )
            end
        end
    end
end

return Grid
