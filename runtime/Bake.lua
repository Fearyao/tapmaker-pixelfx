-- ============================================================================
-- fx/Bake.lua — 运行时烘焙：把 pixelfx 特效渲成一张图集纹理
--
-- 为什么不每帧现画：引擎只有 Image:SetPixelInt 一条写像素的路，136×80 一帧约 3.3 ms，
-- 同屏几个特效就爆帧（详见 PORTING.md 的成本表）。所以整条链是：
--
--   移植版特效 → 逐帧画进 Image → 上传 Texture2D（图集） → 播放器每帧只改 UV
--
-- 烘焙是**预算化**的：每帧最多花 BUDGET_MS 毫秒，做完一帧才上传。于是运行期不会
-- 出现一帧 200ms 的卡顿，代价是特效要等几百毫秒才可用（job.ready 之前调用方先别显示）。
-- 开局可以用 Bake.flush(ms) 一次性付掉常用特效的成本。
--
-- 缓存键 = 特效 id + 影响像素的一切选项（色板/种子/翻转/角度/帧数），
-- 所以「同一特效四种弹体色」只会多烤几份图集，代码只有一份。
-- ============================================================================

local Core = require "tap-pixelfx.core.Core"

local Bake = {}

local floor, ceil, sqrt = math.floor, math.ceil, math.sqrt

-- 每帧烘焙预算（毫秒）。手机端建议 1.0–1.5；桌面可以放宽到 3。
Bake.BUDGET_MS = 1.2

-- 调试 / 构建期用：烤完保留 job.image，供 Bake.exportSheet 写盘。游戏里保持 false
-- （每份图集 4 字节/像素，留着就是纯占内存）。
Bake.retainImages = false

-- 调试用：开成 true 时逐阶段计时（模拟 / 合成 / 上传），数据挂在 job.timing 上
Bake.profile = false

-- 调试用：设成目录后，每份图集烤完会另存一张 PNG 到那里（验收时肉眼/比对用）。
-- 游戏里保持 nil，别让它每局往磁盘写图。
Bake.captureDir = nil

-- 图集里每格四周留 1px 透明边。播放器把图集整张贴上去、靠 pattern 偏移取格，
-- 没有这道边，格子边缘会被邻居或双线性采样渗色（一圈脏边）。
Bake.PAD = 1

local SPECS = {}   -- id -> { meta, make(opts) -> { step(i), paint(p) } }
local JOBS = {}    -- key -> job（含排队与已完成）
local QUEUE = {}   -- 待烘的 key，FIFO
local STATS = { baked = 0, frames = 0, ms = 0 }

local function now()
    local ok, t = pcall(os.clock)
    if ok and type(t) == "number" then
        return t
    end
    return 0
end

--- 注册一个可烘焙的特效
---@param id string
---@param spec table { meta = table, make = function(opts) }
function Bake.register(id, spec)
    SPECS[id] = spec
end

--- 纯函数特效（模块提供 draw(p, t, opts) / drawBack）
---@param meta table
---@param mod table
---@return table
function Bake.pureSpec(meta, mod)
    return {
        meta = meta,
        make = function(opts)
            return {
                step = function() end,
                paint = function(p, t)
                    if mod.drawBack ~= nil then
                        mod.drawBack(p, t, opts)
                    end
                    mod.draw(p, t, opts)
                end,
            }
        end,
        pure = true,
    }
end

--- 有状态特效（模块提供 new(opts) / update / draw）
---@param meta table
---@param mod table
---@return table
function Bake.instSpec(meta, mod)
    return {
        meta = meta,
        make = function(opts)
            local inst = mod.new(opts)
            return {
                step = function(i)
                    if i > 0 then
                        inst:update(1 / meta.fps)
                    end
                end,
                paint = function(p)
                    -- 实例可以有 drawBack（画在角色/地面之后的层），顺序和 createFx 一致
                    if inst.drawBack then
                        inst:drawBack(p)
                    end
                    inst:draw(p)
                end,
            }
        end,
    }
end

--- 缓存键：同一个特效 + 同色板 + 同种子/翻转/角度才复用同一张图集
---@param id string
---@param opts table|nil
---@return string
function Bake.keyOf(id, opts)
    opts = opts or {}
    local parts = { id }
    local palette = opts.palette
    if palette ~= nil then
        parts[#parts + 1] = (type(palette) == "table") and table.concat(palette, ",") or tostring(palette)
    end
    for _, name in ipairs({ "slug", "core", "sparks", "haze", "smoke" }) do
        local v = opts[name]
        if v ~= nil then
            parts[#parts + 1] = name .. "=" .. ((type(v) == "table") and table.concat(v, ",") or tostring(v))
        end
    end
    parts[#parts + 1] = "s" .. tostring(opts.seed or 0)
    parts[#parts + 1] = opts.flip and "f" or "-"
    parts[#parts + 1] = "a" .. tostring(opts.angle or 0)
    if opts.frames ~= nil then
        parts[#parts + 1] = "n" .. tostring(opts.frames)
    end
    return table.concat(parts, "|")
end

--- 判断一个选项值是不是「色带」（色值列表）
local function isRamp(v)
    if type(v) ~= "table" or #v == 0 then
        return false
    end
    for i = 1, #v do
        local c = v[i]
        if type(c) ~= "number" and not (type(c) == "string" and c:match("^#%x%x%x%x?%x?%x?$")) then
            return false
        end
    end
    return true
end

--- 特效选项 = meta.options 的默认值 + 调用方覆盖
--- 和原版 resolveOptions 一样：同名的色带如果长度不同，重采样到默认长度，
--- 这样特效内部按 C[5] 取台阶永远是安全的。
---@param meta table
---@param opts table|nil
---@return table
function Bake.resolveOptions(meta, opts)
    local defaults = meta.options or {}
    local out = {}
    for k, v in pairs(defaults) do
        out[k] = v
    end
    for k, v in pairs(opts or {}) do
        out[k] = v
    end
    for k, def in pairs(defaults) do
        local given = (opts or {})[k]
        if isRamp(def) and isRamp(given) and #given ~= #def then
            out[k] = Core.fit(given, #def)
        end
    end
    return out
end

--- 帧里有内容的矩形（没有内容返回 nil）
local function contentRect(f)
    local w, h = f.w, f.h
    local x0, y0, x1, y1 = w, h, -1, -1
    for y = 0, h - 1 do
        local base = y * w
        for x = 0, w - 1 do
            local i = base + x
            if f.color[i] ~= 0 or f.light[i] ~= 0 then
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

--- 建一个烘焙任务（不立即干活）
local function newJob(key, id, spec, opts)
    local meta = spec.meta
    opts = Bake.resolveOptions(meta, opts)
    local w, h = meta.size[1], meta.size[2]
    local count = floor(meta.duration * meta.fps + 0.5)
    if not meta.loop then
        count = count + 1
    end
    -- opts.frames 可以只烤前 N 帧：烟/弹壳拖太久的一次性特效，玩起来只需要前 0.6 秒
    if type(opts.frames) == "number" and opts.frames >= 1 and opts.frames < count then
        count = floor(opts.frames)
    end
    if count < 1 then
        count = 1
    end
    local cols = ceil(sqrt(count))
    local rows = ceil(count / cols)
    local pad = Bake.PAD
    local cw, ch = w + pad * 2, h + pad * 2
    local aw, ah = cols * cw, rows * ch

    local img = Image()
    img:SetSize(aw, ah, 4)
    img:ClearInt(0)

    local job = {
        key = key,
        id = id,
        meta = meta,
        opts = opts,
        frames = count,
        fps = meta.fps,
        w = w,
        h = h,
        cols = cols,
        rows = rows,
        pad = pad,
        cw = cw,
        ch = ch,
        aw = aw,
        ah = ah,
        ox = meta.origin[1],
        oy = meta.origin[2],
        image = img,
        frame = Core.createFrame(w, h, 0, 0),
        rgba = {},
        i = 0,
        ready = false,
        texture = nil,
        ms = 0,
        timing = Bake.profile and { sim = 0, comp = 0, up = 0, px = 0, box = 0 } or nil,
    }
    job.painter = Core.newPainter(job.frame)
    local prod = spec.make(opts)
    job.producer = {
        step = function(i)
            prod.step(i)
        end,
        paint = function(p)
            if spec.pure then
                local t
                local raw = (job.i) / meta.fps
                if meta.loop then
                    t = raw % meta.duration
                else
                    t = math.min(raw, meta.duration)
                end
                prod.paint(p, t)
            else
                prod.paint(p)
            end
        end,
    }
    return job
end

--- 烘一帧：清帧 → 摆放 → 画 → 只合成有内容的矩形 → 写进图集对应格子
local function bakeOneFrame(job)
    if job.startedAt == nil then
        job.startedAt = now()
    end
    local tSim = now()
    local f = job.frame
    Core.clearFrame(f)
    job.producer.step(job.i)
    job.painter:reset():place(job.ox, job.oy, job.opts.flip and true or false, job.opts.angle or 0)
    job.producer.paint(job.painter)
    if job.timing then
        local t = now()
        job.timing.sim = job.timing.sim + (t - tSim) * 1000
        tSim = t
    end

    local x0, y0, x1, y1 = contentRect(f)
    if x0 ~= nil then
        Core.composite(f, job.rgba, nil, x0, y0, x1, y1)
        if job.timing then
            local t = now()
            job.timing.comp = job.timing.comp + (t - tSim) * 1000
            tSim = t
        end
        local cx = (job.i % job.cols) * job.cw + job.pad
        local cy = floor(job.i / job.cols) * job.ch + job.pad
        local img = job.image
        local w = f.w
        local rgba = job.rgba
        local written = 0
        for y = y0, y1 do
            local base = y * w
            for x = x0, x1 do
                local j = (base + x) * 4
                local al = rgba[j + 4]
                -- 全透明像素不用写：图集建好时整张 ClearInt(0)，空着就是空
                -- （内容矩形里往往一半以上是空洞，这一步省下的是纯 Lua→C 调用）
                if al ~= 0 then
                    -- composite 写的是 R,G,B,A 顺序；引擎的打包色是 #AABBGGRR
                    local packed = (al << 24)
                        | ((rgba[j + 3] & 0xFF) << 16)
                        | ((rgba[j + 2] & 0xFF) << 8)
                        | (rgba[j + 1] & 0xFF)
                    img:SetPixelInt(cx + x, cy + y, packed)
                    written = written + 1
                end
            end
        end
        if job.timing then
            job.timing.up = job.timing.up + (now() - tSim) * 1000
            job.timing.px = job.timing.px + written
            job.timing.box = job.timing.box + (x1 - x0 + 1) * (y1 - y0 + 1)
        end
    end
    job.i = job.i + 1
end

--- 收尾：整张图集上传成一张纹理
local function finishJob(job)
    local tex = Texture2D()
    tex:SetNumLevels(1)
    tex:SetFilterMode(FILTER_NEAREST)
    tex:SetSize(job.aw, job.ah, Graphics:GetRGBAFormat(), TEXTURE_STATIC)
    tex:SetData(job.image, false)
    if Bake.captureDir ~= nil then
        local name = job.id:gsub("[/\\]", "_") .. "_" .. tostring(job.frames) .. "f.png"
        local path = Bake.captureDir .. "/" .. name
        local saved = job.image:SavePNG(path)
        if Bake.verbose then
            print(string.format("[fx] 图集导出 %s -> %s", job.id, saved and path or "失败"))
        end
    end
    job.texture = tex
    job.ready = true
    if job.startedAt ~= nil then
        job.ms = (now() - job.startedAt) * 1000
    end
    job.frame = nil
    job.rgba = nil
    job.painter = nil
    job.producer = nil
    if not Bake.retainImages then
        job.image = nil
    end
    STATS.baked = STATS.baked + 1
    STATS.frames = STATS.frames + job.frames
    if Bake.verbose then
        print(string.format(
            "[fx] 烘焙完成 %s：%d 帧 %dx%d → 图集 %dx%d（%.1f ms）",
            job.id, job.frames, job.w, job.h, job.aw, job.ah, job.ms
        ))
    end
end

--- 请求一个特效的图集（可能还没烤好，用 job.ready 判断）
---@param id string
---@param opts table|nil
---@return table|nil job
function Bake.request(id, opts)
    local spec = SPECS[id]
    if spec == nil then
        print("[fx] 未注册的特效: " .. tostring(id))
        return nil
    end
    local key = Bake.keyOf(id, opts)
    local job = JOBS[key]
    if job ~= nil then
        return job
    end
    job = newJob(key, id, spec, opts or {})
    JOBS[key] = job
    QUEUE[#QUEUE + 1] = key
    return job
end

--- 预热：开局把常用特效先排进烘焙队列
--- 条目可以是 id 字符串，也可以是 { id = ..., opts = ... }
--- ⚠️ opts 必须和运行时真正用的一致，否则缓存键不同会白烤一份
---@param entries (string|table)[]
function Bake.prewarm(entries)
    for i = 1, #entries do
        local e = entries[i]
        if type(e) == "string" then
            Bake.request(e)
        else
            Bake.request(e.id, e.opts)
        end
    end
end

--- 同步把队列烤到 maxMs 为止（开局加载期用：一次性付掉，避免运行中掉帧）
---@param maxMs number|nil
---@return integer pending 还有多少帧没烤
function Bake.flush(maxMs)
    local t0 = now()
    local budget = maxMs or 200
    while #QUEUE > 0 do
        local job = JOBS[QUEUE[1]]
        if job == nil or job.ready then
            table.remove(QUEUE, 1)
        else
            bakeOneFrame(job)
            if job.i >= job.frames then
                finishJob(job)
                table.remove(QUEUE, 1)
            end
            if (now() - t0) * 1000 >= budget then
                break
            end
        end
    end
    return Bake.pending()
end

--- 每帧推进烘焙队列（有预算上限）
---@param dt number
function Bake.update(dt)
    if #QUEUE == 0 then
        return
    end
    local t0 = now()
    while #QUEUE > 0 do
        local key = QUEUE[1]
        local job = JOBS[key]
        if job == nil or job.ready then
            table.remove(QUEUE, 1)
        else
            while job.i < job.frames do
                -- 先看预算再干活：单帧成本可能就超过预算，至少别在一帧里连烤好几帧
                if (now() - t0) * 1000 >= Bake.BUDGET_MS then
                    break
                end
                bakeOneFrame(job)
            end
            if job.i < job.frames then
                return
            end
            finishJob(job)
            table.remove(QUEUE, 1)
            if (now() - t0) * 1000 >= Bake.BUDGET_MS then
                return
            end
        end
    end
end

--- 还有多少帧没烤完（调试 / 自检用）
---@return integer
function Bake.pending()
    local n = 0
    for i = 1, #QUEUE do
        local job = JOBS[QUEUE[i]]
        if job ~= nil and not job.ready then
            n = n + (job.frames - job.i)
        end
    end
    return n
end

---@return table
function Bake.stats()
    return { baked = STATS.baked, frames = STATS.frames, pending = Bake.pending() }
end

--- 已注册的特效 id 列表
---@return string[]
function Bake.ids()
    local out = {}
    for id in pairs(SPECS) do
        out[#out + 1] = id
    end
    table.sort(out)
    return out
end

--- 某个已注册特效的 meta（没注册返回 nil）
---@param id string
---@return table|nil
function Bake.meta(id)
    local spec = SPECS[id]
    return spec and spec.meta or nil
end

--- 构建期：把一份烤好的图集连同描述符写到磁盘（PNG + JSON）
---
--- 描述符刻意和播放器的字段一一对应，播放器读它就不用再问 Bake。
---@param job table Bake.request 返回的任务（需要 Bake.retainImages = true）
---@param jsonPath string 目标 JSON 路径（PNG 写在同目录、同名的 .png）
---@return boolean ok
function Bake.exportSheet(job, jsonPath)
    if job == nil or not job.ready or job.image == nil then
        return false
    end
    -- 目标目录可能还不存在（首次导出）：逐级建出来
    local dir = jsonPath:match("^(.*)/[^/]+$")
    if dir ~= nil and fileSystem then
        local acc = ""
        for part in dir:gmatch("[^/]+") do
            acc = (acc == "" and part or (acc .. "/" .. part))
            if not fileSystem:DirExists(acc) then
                fileSystem:CreateDir(acc)
            end
        end
    end
    local pngPath = jsonPath:gsub("%.json$", ".png")
    if not job.image:SavePNG(pngPath) then
        return false
    end
    local name = pngPath:match("([^/]+)$")
    local desc = {
        id = job.id,
        image = name,
        aw = job.aw,
        ah = job.ah,
        w = job.w,
        h = job.h,
        pad = job.pad,
        cw = job.cw,
        ch = job.ch,
        cols = job.cols,
        rows = job.rows,
        frames = job.frames,
        fps = job.fps,
        loop = job.meta.loop == true,
        origin = { job.ox, job.oy },
    }
    local file = File()
    if not file:Open(jsonPath, FILE_WRITE) then
        return false
    end
    -- WriteString 会多写一个 NUL；WriteLine 只加 CRLF（JSON 解析器容忍尾随空白）
    file:WriteLine(cjson.encode(desc))
    file:Close()
    return true
end

--- 清空（重开一局 / 自检用）
function Bake.clear()
    JOBS = {}
    QUEUE = {}
    STATS = { baked = 0, frames = 0, ms = 0 }
end

return Bake
