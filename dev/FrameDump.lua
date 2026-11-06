-- ============================================================================
-- fx/dev/FrameDump.lua — 按「游戏里怎么放」把特效渲成一串 RGBA 帧
--
-- 这是移植验收台的共用件：它不碰任何引擎 API，只在纯 Lua 里跑 Core + 特效模块，
-- 所以同一条路径既能在引擎里跑（-validate），也能在 wasmoon 里跑（node 侧对拍）。
--
-- 步进规则和 pixelfx 的 createFx 完全一致：
--   * 第 0 帧不 update，之后每帧先 update(1/fps) 再画
--   * 有状态特效（有 new/update/draw）自己负责把 dt 细分到 120Hz 以上
--   * 纯函数特效（draw(p, t, opts)）的 t = 帧号/fps，循环特效取模、一次性特效封顶
--   * 画布原点放在 meta.origin，flip/angle 作为 painter 的摆放
-- ============================================================================

local Core = require "tap-pixelfx.core.Core"

local FrameDump = {}

local floor = math.floor

--- 一个特效按 meta 应该出多少帧（和 Bake 的取帧规则一致）
---@param meta table
---@param opts table|nil
---@return integer
function FrameDump.frameCount(meta, opts)
    opts = opts or {}
    local count = floor(meta.duration * meta.fps + 0.5)
    if not meta.loop then
        count = count + 1
    end
    if type(opts.frames) == "number" and opts.frames >= 1 and opts.frames < count then
        count = floor(opts.frames)
    end
    if count < 1 then
        count = 1
    end
    return count
end

--- meta.options 的默认值 + 调用方覆盖（和 createFx 的 resolveOptions 同一语义）
---@param meta table
---@param opts table|nil
---@return table
function FrameDump.resolveOptions(meta, opts)
    local out = {}
    for k, v in pairs(meta.options or {}) do
        out[k] = v
    end
    for k, v in pairs(opts or {}) do
        out[k] = v
    end
    return out
end

--- 画一帧：清帧 → 摆放 → 画 → 合成
---@param meta table
---@param painter table
---@param frame table
---@param rgba table
---@param t number
---@param drawBack function|nil
---@param draw function
---@param opts table
local function paintFrame(meta, painter, frame, rgba, t, drawBack, draw, opts)
    local ox, oy = meta.origin[1], meta.origin[2]
    Core.clearFrame(frame)
    painter:reset():place(ox, oy, opts.flip and true or false, opts.angle or 0)
    if drawBack then
        drawBack(painter, t, opts)
    end
    draw(painter, t, opts)
    Core.composite(frame, rgba, nil)
end

--- 把特效渲出来，每帧回调一次 onFrame(index, rgba, w, h)
---@param mod table 特效模块
---@param opts table|nil 选项（palette/seed/...）
---@param onFrame fun(i: integer, rgba: number[], w: integer, h: integer)
---@return integer count 帧数
function FrameDump.capture(mod, opts, onFrame)
    local meta = mod.meta
    local w, h = meta.size[1], meta.size[2]
    local fps = meta.fps
    local D = meta.duration
    local frame = Core.createFrame(w, h, 0, 0)
    local painter = Core.newPainter(frame)
    local rgba = {}
    local count = FrameDump.frameCount(meta, opts)
    opts = FrameDump.resolveOptions(meta, opts)

    if mod.new then
        -- 有状态特效：t 由实例自己攒，painter 每帧重摆一次
        local inst = mod.new(opts)
        for i = 0, count - 1 do
            if i > 0 then
                inst:update(1 / fps)
            end
            Core.clearFrame(frame)
            painter:reset():place(meta.origin[1], meta.origin[2], opts.flip and true or false, opts.angle or 0)
            -- 和 createFx 一样：实例也可以有 drawBack，先画 back 层再画 front 层
            if inst.drawBack then
                inst:drawBack(painter)
            end
            inst:draw(painter)
            Core.composite(frame, rgba, nil)
            onFrame(i, rgba, w, h)
        end
        return count
    end

    local draw = mod.draw
    local drawBack = mod.drawBack
    for i = 0, count - 1 do
        local raw = i / fps
        local t
        if meta.loop then
            t = raw % D
        else
            t = math.min(raw, D)
        end
        paintFrame(meta, painter, frame, rgba, t, drawBack, draw, opts)
        onFrame(i, rgba, w, h)
    end
    return count
end

--- 一帧里「有内容」的矩形（合成/上传只处理这块）
---@param frame table
---@return integer|nil x0, integer|nil y0, integer|nil x1, integer|nil y1
function FrameDump.contentRect(frame)
    local w, h = frame.w, frame.h
    local x0, y0, x1, y1 = w, h, -1, -1
    for y = 0, h - 1 do
        local base = y * w
        for x = 0, w - 1 do
            local i = base + x
            if frame.color[i] ~= 0 or frame.light[i] ~= 0 then
                if x < x0 then x0 = x end
                if x > x1 then x1 = x end
                if y < y0 then y0 = y end
                if y > y1 then y1 = y end
            end
        end
    end
    if x1 < x0 then
        return nil
    end
    return x0, y0, x1, y1
end

--- 把一帧的 rgba 表拼成字节串（Lua 5.4 string.char 一次性构造）
---@param rgba number[]
---@param n integer|nil 有效字节数（默认 #rgba）
---@return string
function FrameDump.pack(rgba, n)
    n = n or #rgba
    local parts = {}
    for i = 1, n, 4096 do
        local stop = math.min(i + 4095, n)
        local bytes = {}
        for j = i, stop do
            bytes[#bytes + 1] = string.char(rgba[j])
        end
        parts[#parts + 1] = table.concat(bytes)
    end
    return table.concat(parts)
end

return FrameDump
