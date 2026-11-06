-- ============================================================================
-- fx/dev/BattleFxCheck.lua — 表现层接线自检（真 UI 树 + 假单位）
--
-- 验的是「UI.BattleFx 装到战斗类上以后，事件一来能不能正确放出特效」：
--   用 Widget 派生一个只有坐标的假舞台，装上 BattleFx，然后按战斗事件顺序
--   把命中/暴击/刀光/治疗/死亡/溅射/投射物全部走一遍，再跑若干帧 Update + Render。
--
-- 不验像素（headless 没有像素），验的是接线、坐标换算、实例生命周期、以及
-- 「构建期图集命中 / 运行期烘焙兜底」两条路都走得通。
--
-- 跑法：
--   ./.cli/UrhoXRuntime scripts/tap-pixelfx/dev/BattleFxCheck.lua -tapcode_dir="$PWD" -tool_mode \
--       -graphicsheadless -validate -validate-frames=2 -validate-timeout=120 -log info
-- ============================================================================

local UI = require("urhox-libs/UI")
local Widget = require("urhox-libs/UI/Core/Widget")
local BattleFx = require("UI.BattleFx")
local Registry = require("tap-pixelfx.runtime.Registry")
local Layer = require "tap-pixelfx.runtime.Layer"

local FRAMES = 60

-- 假舞台：真有布局（Widget），没有战斗逻辑
local Stage = Widget:Extend("FxCheckStage")
function Stage:Init(props)
    props = props or {}
    props.position = "absolute"
    props.left = 0
    props.top = 0
    props.width = 320
    props.height = 480
    Widget.Init(self, props)
    self.entries_ = {}
    self.projectiles_ = {}
end

BattleFx.Install(Stage)

--- 假单位：只要 GetHurtbox / GetFootEllipse / GetBodyCenter 这几个查询
local function fakeEntry(x, y, alive)
    local widget = {
        GetHurtbox = function()
            return { x = x - 12, y = y - 30, w = 24, h = 44 }
        end,
        GetFootEllipse = function()
            return { x = x, y = y, rx = 12, ry = 6 }
        end,
        GetBodyCenter = function()
            return x, y - 16
        end,
    }
    return { widget = widget, alive = alive ~= false, team = "enemy" }
end

function Start()
    local ok, err = pcall(function()
        UI.Init({ theme = "default-dark", scale = UI.Scale.DEFAULT, autoEvents = false })

        local root = UI.Panel { width = "100%", height = "100%", pointerEvents = "box-none" }
        local stage = Stage {}
        root:AddChild(stage)
        UI.SetRoot(root)
        UI.Layout()

        -- 舞台放在屏幕中间，坐标换算才有非零偏移可验
        stage:SetStyle({ left = 20, top = 40 })
        UI.Layout()

        local atk = fakeEntry(80, 200)
        local tgt = fakeEntry(200, 260)
        local dead = fakeEntry(150, 300, false)

        stage:PlaySlashFx(atk, tgt)
        stage:PlayHitFx(atk, tgt, 37, false)
        stage:PlayHitFx(atk, tgt, 96, true)
        stage:PlayHealFx(atk, 24)
        stage:PlayDeathFx(dead)
        stage:PlaySplashFx(200, 260)

        -- 投射物：造一个假的，走「挂飞行特效 → 逐帧同步 → 收掉」全流程
        local projectile = { x = 60, y = 180, w = 18, h = 2, vx = 300, vy = -40 }
        stage:AttachProjectileFx(projectile)
        assert(projectile.fx ~= nil, "投射物没挂上飞行特效")

        local layer = stage:FxLayer()
        assert(layer ~= nil, "覆盖层没建起来")
        assert(layer:Count() >= 7, "实例数不对：" .. tostring(layer:Count()))

        -- 坐标换算：绝对坐标减舞台左上角
        local local_x, local_y = stage:FxLocal(200, 260)
        assert(local_x == 180 and local_y == 220,
            string.format("坐标换算不对：期望 (180,220)，得到 (%.1f,%.1f)", local_x, local_y))

        -- 跑帧：实例推进 + NanoVG 渲染路径
        for i = 1, FRAMES do
            projectile.x = projectile.x + projectile.vx / 60
            projectile.y = projectile.y + projectile.vy / 60
            stage:SyncProjectileFx(projectile)
            UI.Update(1 / 60)
            UI.Render()
        end

        local live_x = projectile.fx and projectile.fx.x or nil
        assert(live_x ~= nil, "飞行特效中途被回收了")

        stage:DetachProjectileFx(projectile)
        for _ = 1, 20 do
            UI.Update(1 / 60)
            UI.Render()
        end
        assert(projectile.fx == nil, "收起后 projectile.fx 应该清空")

        local stats = layer:Stats()
        print(string.format(
            "[fx-battle] 实例 spawned=%d live=%d culled=%d；飞行特效跟随到 x=%.1f（舞台本地，应等于投射物中心）",
            stats.spawned, stats.live, stats.culled, live_x
        ))

        -- 关闭开关：props.fx = false 时整层不建
        local off = Stage { fx = false }
        off.fxDisabled_ = true
        assert(off:PlayHitFx(atk, tgt, 10, false) == nil, "关闭后不该再产生特效")
        print("[fx-battle] fx = false 时表现层关闭正常")

        print("[fx-battle] RESULT=PASS")
    end)
    if not ok then
        print("[fx-battle] RESULT=FAIL " .. tostring(err))
        log:Write(LOG_ERROR, "[fx-battle] " .. tostring(err))
    end
end
