-- ============================================================================
-- fx/dev/FxRuntimeCheck.lua — 运行期接线自检（引擎 headless 就能跑）
--
-- 检查的是「接进游戏以后会不会炸」，不是像素：
--   1. 注册表能加载、构建期图集的描述符全都能读到、字段自洽
--   2. 覆盖层能创建、每个特效都能 spawn 出一个实例
--   3. 跑若干帧 Update + Render（NanoVG 调用全部过一遍；headless 没有像素但不该报错）
--   4. 运行期烘焙兜底路径（带 palette 的自定义）也能跑通并最终 ready
--
-- 跑法：
--   ./.cli/UrhoXRuntime scripts/tap-pixelfx/dev/FxRuntimeCheck.lua -tapcode_dir="$PWD" -tool_mode \
--       -graphicsheadless -validate -validate-frames=2 -validate-timeout=120 -log info
-- ============================================================================

local UI = require("urhox-libs/UI")
local Bake = require "tap-pixelfx.runtime.Bake"
local Registry = require "tap-pixelfx.runtime.Registry"
local Layer = require "tap-pixelfx.runtime.Layer"
local Sheets = require "tap-pixelfx.runtime.Sheets"

local FRAMES = 30

function Start()
    local ok, err = pcall(function()
        UI.Init({ theme = "default-dark", scale = UI.Scale.DEFAULT, autoEvents = false })
        Registry.register()

        -- 0) 对拍清单必须和注册表一致：manifest 少一条，CI 就会漏检一个特效
        local mf = cache:GetFile("tap-pixelfx/dev/manifest.json")
        assert(mf ~= nil, "读不到 dev/manifest.json")
        local list = cjson.decode(mf:ReadString())
        assert(#list == #Registry.ids(),
            string.format("manifest 有 %d 条、注册表有 %d 个特效", #list, #Registry.ids()))
        local seen = {}
        for _, entry in ipairs(list) do
            assert(Registry.MODULES[entry.id] == entry.module,
                "manifest 与 Registry.MODULES 不一致: " .. tostring(entry.id))
            seen[entry.id] = true
        end
        for _, id in ipairs(Registry.ids()) do
            assert(seen[id], "注册表里的特效没进 manifest: " .. id)
        end
        print(string.format("[fx-check] manifest %d 条与注册表一致", #list))

        -- 1) 描述符
        local sheetCount = 0
        for id, sheet in pairs(Registry.SHEETS) do
            local desc = Sheets.descriptor(sheet.json)
            assert(desc ~= nil, "图集描述符读不到: " .. sheet.json)
            assert(desc.frames > 0, id .. ": frames 必须是正数")
            assert(desc.cw >= desc.w and desc.ch >= desc.h, id .. ": 格子尺寸必须 >= 画布内容尺寸")
            assert(desc.cols * desc.rows >= desc.frames, id .. ": 图集格子不够放下所有帧")
            sheetCount = sheetCount + 1
        end
        print(string.format("[fx-check] 构建期图集 %d 份全部就绪", sheetCount))

        -- 2) 覆盖层 + 实例
        local root = UI.Panel { width = "100%", height = "100%", pointerEvents = "box-none" }
        UI.SetRoot(root)
        local layer = Layer.new(root)
        assert(layer ~= nil, "覆盖层创建失败")

        local spawned, ids = 0, {}
        for id in pairs(Registry.SHEETS) do
            local e = layer:Spawn(id, 120, 200)
            assert(e ~= nil, "spawn 失败: " .. id)
            assert(e.src.frames > 0, id .. ": 实例帧数为 0")
            -- 有构建期图集的 id，默认参数必须真的走图集（否则就是在偷偷现烤）
            assert(e.src.kind == "sheet", id .. ": 默认 spawn 应该用构建期图集，实际 " .. tostring(e.src.kind))
            local scale = Registry.DEFAULT_SCALE[id]
            assert(scale ~= nil and e.scale == scale, id .. ": 默认缩放没生效")
            ids[#ids + 1] = id
            spawned = spawned + 1
        end
        assert(Bake.pending() == 0, "默认 spawn 不该产生烘焙任务，实际待烤 " .. tostring(Bake.pending()))
        table.sort(ids)
        print(string.format("[fx-check] 实例 %d 个：%s", spawned, table.concat(ids, ", ")))

        -- 3) 跑帧：Update 推进实例 + 烘焙队列，Render 把 NanoVG 调用过一遍
        for i = 1, FRAMES do
            UI.Update(1 / 60)
            UI.Render()
            if i % 10 == 0 then
                print(string.format("[fx-check] 第 %d 帧：live=%d 烘焙待烤=%d", i, layer:Count(), Bake.pending()))
            end
        end

        -- 4) 画出去的实例数（headless 没有 GPU 时通常是 0，这里只报告不判定）
        print(string.format("[fx-check] 最近一帧实际画出的实例数: %d", layer:Stats().drawn))

        -- 5) 运行期烘焙兜底：显式换色板 → 绕开图集，现场烤
        local custom = layer:Spawn(Registry.HIT, 60, 60, { palette = { "#102030", "#2050a0", "#40a0ff" } })
        assert(custom ~= nil, "自定义色板实例创建失败")
        assert(custom.src.kind == "bake", "自定义色板应该走运行期烘焙，却用了构建期图集")
        local job = custom.src.job
        for _ = 1, 600 do
            layer:Update(1 / 60)
            if job.ready then
                break
            end
        end
        assert(job.ready, "运行期烘焙没能在 600 帧内烤完")
        print(string.format("[fx-check] 运行期烘焙兜底：%s %d 帧 %.1f ms", job.id, job.frames, job.ms))

        local stats = layer:Stats()
        print(string.format(
            "[fx-check] 统计：spawned=%d live=%d culled=%d skipped=%d",
            stats.spawned, stats.live, stats.culled, stats.skipped
        ))
        print("[fx-check] RESULT=PASS")
    end)
    if not ok then
        print("[fx-check] RESULT=FAIL " .. tostring(err))
        log:Write(LOG_ERROR, "[fx-check] " .. tostring(err))
    end
end
