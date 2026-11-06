-- ============================================================================
-- tap-pixelfx/runtime/Layer.lua — 把 pixelfx 图集画到 UI 上的播放器
--
-- 一个实例 = 一条记录（图集 + 位置 + 缩放 + 进度）。渲染全在一个覆盖层 Widget 里
-- 一次性循环完成：每帧只是给每个实例算一次 NanoVG image pattern 的偏移和格子，
-- 没有逐像素成本，也不额外占节点。
--
-- 图集有两个来源，实例结构一致：
--   构建期图集（tap-pixelfx/atlas/**）→ ImageCache → nvgCreateImage，零成本
--   运行期烘焙（runtime/Bake.lua）   → Texture2D → nvgCreateVideo，按预算烤
-- 调用方不需要关心用的是哪条。
--
-- 坐标：spawn 的 (x, y) 是特效的「锚点」（meta.origin，命中点/脚下）在本容器里的
-- 基础像素坐标。特效自己围着这个点画，播放器不用知道画布多大。
--
-- 用法：
--   local Pixelfx = require("tap-pixelfx")
--   local layer = Pixelfx.newLayer(stageWidget)
--   local layer = Layer.Layer { parent = stageWidget }   -- 或 stage:AddChild(Layer.Layer{})
--   layer:Spawn(Pixelfx.presets.HIT, x, y, { scale = 0.5 })
-- ============================================================================

local Widget = require("urhox-libs/UI/Core/Widget")
local Bake = require("tap-pixelfx.runtime.Bake")
local Effects = require("tap-pixelfx.runtime.Registry")
local Sheets = require("tap-pixelfx.runtime.Sheets")

local Layer = {}

local floor = math.floor

-- 覆盖层默认压在单位之上：BattleUnit 的 zIndex 最大约 1e8，这里给更大的一档
Layer.DEFAULT_Z_INDEX = 2e9
-- 有构建期 sheet 就优先用它（零烘焙成本）；运行期烘焙只兜底「要换色板/种子」的场合
Layer.preferSheets = true
Layer.MAX_LIVE = 48         -- 单个覆盖层的实例上限（超出丢最老的）
Layer.DEFAULT_FADE = 0.14   -- 默认淡出时长（秒）

-- ---------------------------------------------------------------------------
-- 图集 → NanoVG 图像句柄（每个 Texture2D 一份，跟着 nvg context 走）
-- ---------------------------------------------------------------------------
local function nvgImageOf(nvg, src)
    if src.kind == "sheet" then
        return Sheets.imageOf(nvg, src)
    end
    -- 运行期烘焙的图集是「烤完才有」的，句柄跟着 job.texture 走，不能缓存在副本里
    local texture = (src.kind == "bake") and src.job.texture or src.texture
    if texture == nil then
        return nil
    end
    if src.nvgCtx ~= nvg then
        -- UI 换过 NanoVG context（重建界面）时旧句柄失效，重新包一次
        if src.nvgImage ~= nil and src.nvgCtx ~= nil and nvgDeleteVideo then
            pcall(nvgDeleteVideo, src.nvgCtx, src.nvgImage)
        end
        src.nvgImage = nil
        src.nvgCtx = nvg
        if nvgCreateVideo then
            local handle = nvgCreateVideo(nvg, texture)
            if handle ~= nil and handle > 0 then
                src.nvgImage = handle
            end
        end
    end
    return src.nvgImage
end

--- 把一次烘焙任务变成播放器要的图集描述
---@param job table
---@return table
local function sourceFromJob(job)
    return {
        kind = "bake",
        id = job.id,
        job = job,
        texture = job.texture,
        ready = job.ready,
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
        ox = job.ox,
        oy = job.oy,
    }
end

--- 解析一个 id + opts 应该用哪份图集：
---   构建期 sheet（assets/image/fx/**）优先，运行期烘焙兜底。
--- 一旦调用方要了非默认的色板/种子/帧数，就只能现场烤 —— 这正是运行期烘焙存在的理由。
---@param id string
---@param opts table
---@return table|nil
function Layer.resolveSource(id, opts)
    if Layer.preferSheets then
        local sheet = Effects.SHEETS[id]
        if sheet ~= nil then
            -- 只有「会改变像素」的选项才逼你回运行期烘焙；
            -- 展示用的 angle / flip / scale / alpha / life 都是画的时候的事，图集照用。
            local customized = (opts.palette ~= nil) or (opts.seed ~= nil) or (opts.frames ~= nil)
            if not customized then
                local desc = Sheets.descriptor(sheet.json)
                if desc ~= nil then
                    return desc, true
                end
            end
        end
    end
    -- 运行期烘焙只吃「影响像素」的选项：镜像/旋转交给播放器画的时候做，
    -- 否则会烤一份转好的图集、播放时再转一次。
    local bakeOpts = {}
    for k, v in pairs(opts) do
        if k ~= "angle" and k ~= "flip" and k ~= "scale" and k ~= "alpha" and k ~= "life"
            and k ~= "fade" and k ~= "delay" and k ~= "loops" then
            bakeOpts[k] = v
        end
    end
    local job = Bake.request(id, bakeOpts)
    if job == nil then
        return nil
    end
    return sourceFromJob(job), false
end

-- ---------------------------------------------------------------------------
-- 覆盖层
-- ---------------------------------------------------------------------------
local LayerWidget = Widget:Extend("LayerWidget")

function LayerWidget:Init(props)
    props = props or {}
    props.position = props.position or "absolute"
    props.left = props.left or 0
    props.top = props.top or 0
    props.width = props.width or "100%"
    props.height = props.height or "100%"
    props.pointerEvents = "none"
    if props.zIndex == nil then
        props.zIndex = Layer.DEFAULT_Z_INDEX
    end
    Widget.Init(self, props)
    self.instances_ = {}
    self.enabled_ = props.enabled ~= false
    self.maxLive_ = props.maxLive or Layer.MAX_LIVE
    self.spawned_ = 0
    self.culled_ = 0
    self.skipped_ = 0
end

--- 每帧推进烘焙队列 + 实例进度（框架对每个带 Update 的 widget 都会调）
function LayerWidget:Update(dt)
    Bake.update(dt)
    local list = self.instances_
    for i = #list, 1, -1 do
        local e = list[i]
        if e.delay > 0 then
            e.delay = e.delay - dt
        else
            e.age = e.age + dt
            if e.age >= e.life then
                table.remove(list, i)
                self.culled_ = self.culled_ + 1
            else
                local idx = floor(e.age * e.fps)
                if e.loop then
                    e.frame = (e.frames > 0) and (idx % e.frames) or 0
                else
                    e.frame = math.min(idx, e.frames - 1)
                end
            end
        end
    end
end

function LayerWidget:Render(nvg)
    local list = self.instances_
    if #list == 0 then
        return
    end
    local layout = self:GetAbsoluteLayout()
    if layout.w > 0 and layout.h > 0 then
        nvgIntersectScissor(nvg, layout.x, layout.y, layout.w, layout.h)
    end
    local drawn = 0
    for i = 1, #list do
        local e = list[i]
        local src = e.src
        local ready = src.ready
        if src.kind == "bake" then
            ready = src.job.ready
        end
        if e.delay <= 0 and ready then
            local img = nvgImageOf(nvg, src)
            if img ~= nil and img > 0 then
                Layer.DrawInstance(nvg, e, img)
                drawn = drawn + 1
            end
        end
    end
    self.drawn_ = drawn
    if drawn == 0 and #list > 0 and not self.warnedNoImage_ then
        -- 图集句柄拿不到（没有 GPU / nvgCreateImage 失败）时只提示一次，不要每帧刷屏
        self.warnedNoImage_ = true
        print("[fx] 警告：实例在跑但一张图集都没画出去（nvg 图像句柄无效），检查 assets/image/fx 是否随包发出")
    end
    return drawn
end

--- 播一个特效。
---@param id string 注册表里的特效 id（见 fx.Effects）
---@param x number 锚点 x（本容器基础像素坐标）
---@param y number 锚点 y
---@param opts table|nil {
---   scale: 每个特效像素占多少基础像素（默认取 Effects.DEFAULT_SCALE）,
---   seed: 随机种子, palette: 色板（hex 列表）,
---   flip: 水平镜像, angle: 弧度旋转,
---   delay: 延后出现的秒数,
---   life: 存活秒数（默认 = 帧数/fps；循环特效用它控制播多久）,
---   loops: 循环特效播几轮（未给 life 时生效）,
---   fade: 淡出秒数, alpha: 整体透明度 }
---@return table|nil instance
function LayerWidget:Spawn(id, x, y, opts)
    if not self.enabled_ then
        self.skipped_ = self.skipped_ + 1
        return nil
    end
    opts = opts or {}
    local src = Layer.resolveSource(id, opts)
    if src == nil then
        return nil
    end

    local frames, fps = src.frames, src.fps
    local loop = src.loop == true
    local life
    if opts.life ~= nil then
        life = opts.life
    elseif loop then
        life = (frames / fps) * (opts.loops or 1)
    else
        life = frames / fps
    end
    local fade = opts.fade
    if fade == nil then
        fade = Layer.DEFAULT_FADE
    end
    if fade > life then
        fade = life
    end

    local e = {
        id = id,
        src = src,
        x = x,
        y = y,
        scale = opts.scale or Layer.defaultScale(id) or 1,
        angle = opts.angle or 0,
        flip = opts.flip == true,
        alpha = opts.alpha or 1,
        delay = opts.delay or 0,
        age = 0,
        frames = frames,
        fps = fps,
        loop = loop,
        life = life,
        fade = fade,
        frame = 0,
    }
    local list = self.instances_
    list[#list + 1] = e
    self.spawned_ = self.spawned_ + 1

    -- 超出上限时丢最老的实例（最老的对应 list[1]）
    while #list > self.maxLive_ do
        table.remove(list, 1)
        self.culled_ = self.culled_ + 1
    end
    return e
end

--- 停掉所有实例（已烤好的图集留着复用）
function LayerWidget:Clear()
    self.instances_ = {}
end

---@return integer
function LayerWidget:Count()
    return #self.instances_
end

---@return table
function LayerWidget:Stats()
    return {
        live = #self.instances_,
        drawn = self.drawn_ or 0,
        spawned = self.spawned_,
        culled = self.culled_,
        skipped = self.skipped_,
        bake = Bake.stats(),
    }
end

--- 覆盖层 Widget 类（想自己派生或手工放进 UI 树时用）
Layer.Widget = LayerWidget

--- 建一个覆盖层并挂到 parent 上
---@param parent Widget
---@param props table|nil { maxLive, zIndex, enabled }
---@return table layer
function Layer.new(parent, props)
    local layer = LayerWidget(props or {})
    if parent ~= nil then
        parent:AddChild(layer)
    end
    return layer
end

--- 每个特效的默认显示缩放（见 runtime/Registry.lua 的 DEFAULT_SCALE）
---@param id string
---@return number|nil
function Layer.defaultScale(id)
    return Effects.DEFAULT_SCALE[id]
end

-- ---------------------------------------------------------------------------
-- 单实例绘制（自检也直接调它）
-- ---------------------------------------------------------------------------

---@param nvg any
---@param e table 实例
---@param img integer NanoVG 图像句柄
function Layer.DrawInstance(nvg, e, img)
    local src = e.src
    local alpha = e.alpha
    if e.fade > 0 then
        local left = e.life - e.age
        if left < e.fade then
            alpha = alpha * math.max(0, left / e.fade)
        end
    end
    if alpha <= 0.004 then
        return
    end

    local s = e.scale
    local cw, ch, pad = src.cw, src.ch, src.pad
    local frameW, frameH = src.w * s, src.h * s
    -- 内容在局部空间里的左上角：锚点（meta.origin）落在 (0, 0)
    local x0, y0 = -src.ox * s, -src.oy * s
    local col = e.frame % src.cols
    local row = floor(e.frame / src.cols)
    -- 图集整张铺开，偏移到「本格内容」正好落在 (x0, y0)
    local pox = x0 - (col * cw + pad) * s
    local poy = y0 - (row * ch + pad) * s

    nvgSave(nvg)
    nvgTranslate(nvg, e.x, e.y)
    if e.angle ~= 0 then
        nvgRotate(nvg, e.angle)
    end
    if e.flip then
        nvgScale(nvg, -1, 1)
    end

    local paint = nvgImagePattern(nvg, pox, poy, src.aw * s, src.ah * s, 0, img, alpha)
    nvgBeginPath(nvg)
    nvgRect(nvg, x0, y0, frameW, frameH)
    nvgFillPaint(nvg, paint)
    nvgFill(nvg)
    nvgRestore(nvg)
end

return Layer
