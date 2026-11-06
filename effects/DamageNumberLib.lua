-- ============================================================================
-- fx/effects/DamageNumberLib.lua — ui/damage-number 的私有小工具
--
-- 原版：pixelfx src/fx/ui/_lib.js 的 spell / drawWord（只搬这两个）
--       + src/core/sim.js 里 STAR 那一支（临时私有一份，原因见下面的 Stars 注释）
--
-- spell：把一串字符按像素字排成一排，返回「每个字的字形 + 左边缘 + 宽度」，坐标是字库像素。
-- drawWord：把这排字当成一整块来画，做到 1 像素级的收边——每个字上亮下暗的渐变、
--   顶边打亮、底边压暗、1 像素暗描边、一层右下投影，外加可选的斜向高光和整块闪白。
--
-- 字库本身不在这里：glyph 数据在 scripts/tap-pixelfx/Font.lua（对应 src/core/font.js），这里只做排版和上色。
-- 注意 ids / edge 是跨帧复用的暂存表（和原版的模块级 Int16Array / Uint8Array 一样）：
-- 每帧先把用到的前 W*H 格清零，再按「字 → 像素」写一遍，所以同一个 t 重放出来逐像素相同。
-- ============================================================================

local Core = require "tap-pixelfx.core.Core"
local Font = require "tap-pixelfx.core.Font"
local Sim = require "tap-pixelfx.core.Sim"

local DamageNumberLib = {}

local floor, ceil, abs, sin, min, max = math.floor, math.ceil, math.abs, math.sin, math.min, math.max

--- 排字：str 按 font 的字形从左到右摆，返回
--- { letters = { { ch, g（空格是 nil）, x（左边缘）, w, h }, ... }, w（总宽）, h }
--- 和原版一样：先按原字符查字形，查不到再按大写查，都没有就当空格宽。
---@param str string
---@param font string|nil "mini" | "big"（默认 big）
---@return table
function DamageNumberLib.spell(str, font)
    local F = Font.FONTS[font or "big"]
    local letters = {}
    local x = 0
    str = tostring(str)
    for i = 1, #str do
        local ch = str:sub(i, i)
        local g = F.glyphs[ch]
        if g == nil then
            g = F.glyphs[ch:upper()]
        end
        local w = g and g.w or F.space
        letters[#letters + 1] = { ch = ch, g = g, x = x, w = w, h = F.h }
        x = x + w + F.gap
    end
    return { letters = letters, w = max(0, x - F.gap), h = F.h }
end

-- ---------------------------------------------------------------------------
-- Stars：数字落地时向两侧弹出去的两颗十字星
--
-- 它们本来是 Particles 的 P.STAR 粒子，但共享的 Sim.lua 在「default 分支」把 JS 的
-- `p.vy -= p.vy * drag * dt + 5 * dt` 写成了 `p.vy = p.vy - p.vy * drag * dt + 5 * dt`
-- （符号反了，等于往上飘 10*dt），STAR 正好落在这个分支里，逐帧累积就飘错位置。
-- 按移植约定不去改共享文件，所以把 STAR 的物理 + 画法原样私有一份，
-- RNG 的消耗点也照抄（spawn 内部那次 next() 用来做 seed），其余粒子仍走 Particles。
-- 等 Sim.lua 修好后，这段可以删掉换回 ps:spawn(Sim.P.STAR, ...)。
-- ---------------------------------------------------------------------------
local Stars = {}
Stars.__index = Stars
DamageNumberLib.Stars = Stars

function DamageNumberLib.newStars()
    return setmetatable({ list = {}, t = 0 }, Stars)
end

--- 对齐 Particles:spawn：实参先算完，最后才消耗一次 Rng 当 seed
function Stars:add(x, y, vx, vy, life, col, size, R)
    self.list[#self.list + 1] = {
        x = x,
        y = y,
        vx = vx,
        vy = vy,
        life = life,
        max = life,
        col = Core.hex(col),
        size = size,
        seed = R:next() * 100,
    }
end

function Stars:update(dt)
    self.t = self.t + dt
    local list = self.list
    for i = #list, 1, -1 do
        local q = list[i]
        q.life = q.life - dt
        if q.life <= 0 then
            table.remove(list, i)
        else
            -- sim.js 的 default 分支：drag 1.6，外加一个恒定的 -5 上飘
            q.vx = q.vx - q.vx * 1.6 * dt
            q.vy = q.vy - (q.vy * 1.6 * dt + 5 * dt)
            q.x = q.x + q.vx * dt
            q.y = q.y + q.vy * dt
        end
    end
end

function Stars:draw(p)
    for _, q in ipairs(self.list) do
        local k = q.life / q.max
        -- 闪烁系数：频率和相位都由粒子自己的 seed 决定（时钟和粒子系统同一口径）
        local tw = 0.6 + 0.4 * sin(self.t * (8 + (q.seed % 5)) + q.seed)
        if q.size < 1 then
            if tw * k > 0.25 then
                p:px(q.x, q.y, (tw > 0.8) and Core.WHITE or q.col)
            end
            p:glow(q.x, q.y, 3, q.col, 0.4 * k * tw)
        else
            Sim.sparkle(p, q.x, q.y, q.size * tw * min(1, k * 3), q.col, Core.scale(q.col, 0.75), 0.5 * k * tw)
        end
    end
end

-- ---------------------------------------------------------------------------
-- drawWord：把一排字当成一块来画
-- ---------------------------------------------------------------------------

-- 跨帧复用的暂存表：ids[i] = 盖住这一格的 items 下标（0 = 空），edge[i] = 收边标志位
local ids, edge = {}, {}

--- 某一行在 gx 这一列「外面」是否空（上一行 / 下一行整段都没墨）：斜笔只有角对角相接时不收边
local function openAt(r, gx)
    if r == nil then
        return true
    end
    return not r[gx + 1] and not r[gx] and not r[gx + 2]
end

--- 画一排字。
--- items: { { g（字形）, x, y（左上，局部像素）, sx, sy（每个字库像素占几个像素）,
---            a（alpha）, flash（0..1 闪白）, slant（斜体，这里没用到） }, ... }
--- st: { fill = { 底..顶 的颜色台阶 }, edge（顶边打亮色）, under（底边压暗色）,
---       outline（描边色）, ow（描边宽，默认 1）, shadow（投影色）, shine / shineY（斜向高光，这里没用到） }
---@param p table Painter
---@param items table
---@param st table
function DamageNumberLib.drawWord(p, items, st)
    if #items == 0 then
        return
    end

    -- 1) 所有字并成一块，外扩 1 + 描边宽，得到临时画布
    local x0, y0 = math.huge, math.huge
    local x1, y1 = -math.huge, -math.huge
    for _, it in ipairs(items) do
        local h, w = it.g.h * it.sy, it.g.w * it.sx
        if it.x < x0 then
            x0 = it.x
        end
        if it.x + w > x1 then
            x1 = it.x + w
        end
        if it.y < y0 then
            y0 = it.y
        end
        if it.y + h > y1 then
            y1 = it.y + h
        end
    end
    local ow = st.ow or 1
    x0 = floor(x0) - 1 - ow
    y0 = floor(y0) - 1 - ow
    x1 = ceil(x1) + 2 + ow
    y1 = ceil(y1) + 3 + ow
    local W, H = x1 - x0, y1 - y0
    local n = W * H
    if n <= 0 then
        return
    end
    for k = 1, n do
        ids[k] = 0
    end

    -- 2) 把每个字的着墨点写进 id 表，同时按「字库像素」算收边：
    --    顶边打亮（1）、底边压暗（2）、左边打亮（4）。斜笔（字库像素只靠角相接）不收边，保持整块。
    for k, it in ipairs(items) do
        local g = it.g
        local gh = g.h
        local bot = it.y + gh * it.sy
        local py = floor(it.y)
        local pyEnd = ceil(bot)
        while py < pyEnd do
            local gy = floor((py + 0.5 - it.y) / it.sy)
            if gy >= 0 and gy < gh then
                local ry = py + 0.5 - it.y - gy * it.sy
                local row = g.rows[gy + 1]
                local up = gy > 0 and g.rows[gy] or nil
                local dn = gy < gh - 1 and g.rows[gy + 2] or nil
                local px = floor(it.x) - 1
                local pxEnd = ceil(it.x + g.w * it.sx)
                while px <= pxEnd do
                    local fx = px + 0.5 - it.x
                    local gx = floor(fx / it.sx)
                    if gx >= 0 and gx < g.w and row[gx + 1] then
                        local i = (py - y0) * W + (px - x0)
                        if i >= 0 and i < n then
                            ids[i + 1] = k
                            local rx = fx - gx * it.sx
                            local e = 0
                            if ry < 1 and openAt(up, gx) then
                                e = e + 1
                            end
                            if ry >= it.sy - 1 and openAt(dn, gx) then
                                e = e + 2
                            end
                            if rx < 1 and not (gx > 0 and row[gx]) then
                                e = e + 4
                            end
                            edge[i + 1] = e
                        end
                    end
                    px = px + 1
                end
            end
            py = py + 1
        end
    end

    -- 3) 逐格上色：字身沿字高取渐变台阶，收边优先，外加闪白；
    --    字外一圈先铺描边，描边外再铺一层右下投影
    local F = st.fill
    local nF = #F
    local at = function(x, y)
        if x < x0 or y < y0 or x >= x1 or y >= y1 then
            return 0
        end
        return ids[(y - y0) * W + (x - x0) + 1]
    end
    for y = y0, y1 - 1 do
        local rowBase = (y - y0) * W - x0
        for x = x0, x1 - 1 do
            local i = rowBase + x
            local id = ids[i + 1]
            if id ~= 0 then
                local it = items[id]
                local v = (y + 0.5 - it.y) / (it.g.h * it.sy)
                local f = min(nF - 1, max(0, floor((1 - v) * nF)))
                local c = F[f + 1]
                local e = edge[i + 1]
                if e & 1 ~= 0 then
                    c = st.edge or F[nF]
                elseif e & 2 ~= 0 then
                    c = st.under or F[1]
                elseif e & 4 ~= 0 and f < nF - 1 then
                    c = F[f + 2]
                end
                if it.flash > 0.6 or (it.flash > 0.25 and v < 0.5) then
                    c = Core.WHITE
                end
                p:dot(x, y, c, it.a)
            else
                -- 描边：邻格只要有一格是字就描（ow > 1 时只取菱形半径内）
                local nb = 0
                local dy = -ow
                while dy <= ow and nb == 0 do
                    local dx = -ow
                    while dx <= ow and nb == 0 do
                        if ow < 2 or abs(dx) + abs(dy) < 4 then
                            nb = at(x + dx, y + dy)
                        end
                        dx = dx + 1
                    end
                    dy = dy + 1
                end
                if nb ~= 0 then
                    p:dot(x, y, st.outline, items[nb].a)
                elseif st.shadow ~= nil then
                    local s = at(x - ow, y - 1 - ow)
                    if s == 0 then
                        s = at(x + 1 - ow, y - 1 - ow)
                    end
                    if s == 0 then
                        s = at(x - ow, y - ow)
                    end
                    if s ~= 0 then
                        p:dot(x, y, st.shadow, items[s].a * 0.9)
                    end
                end
            end
        end
    end
end

return DamageNumberLib
