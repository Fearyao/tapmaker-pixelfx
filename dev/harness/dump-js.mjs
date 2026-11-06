// JS 参考帧导出：用 pixelfx 原版（ESM）渲染一个特效，逐帧落成裸 RGBA。
//
// 步进规则和 scripts/tap-pixelfx/dev/FrameDump.lua 一一对应：第 0 帧不 update，之后
// 每帧 update(1/fps) 再画；back/front 两层画进同一张帧（游戏里也是这么合成的）。
//
// 用法：node scripts/tap-pixelfx/dev/harness/dump-js.mjs <effect-id> <out-dir> [frames]
//   effect-id 是 pixelfx 的 id，例如 impacts/hit-spark
//   PIXELFX_DIR 环境变量指向 pixelfx 仓库（默认 /Users/wyy19940108/game/pixelfx）

import { mkdirSync, writeFileSync, rmSync } from 'node:fs'
import path from 'node:path'
import { pathToFileURL } from 'node:url'

const PIXELFX = process.env.PIXELFX_DIR || '/Users/wyy19940108/game/pixelfx'

const id = process.argv[2]
const outDir = process.argv[3]
const frameArg = process.argv[4] ? Number(process.argv[4]) : null
if (!id || !outDir) {
    console.error('usage: node dump-js.mjs <effect-id> <out-dir> [frames]')
    process.exit(2)
}

const core = await import(pathToFileURL(path.join(PIXELFX, 'src/core/index.js')).href)
const { createFrame, clearFrame, createFx, composite } = core

const mod = await import(pathToFileURL(path.join(PIXELFX, `src/fx/${id}.js`)).href)
const meta = mod.meta ?? {}
const [W, H] = meta.size
const [OX, OY] = meta.origin
const fps = meta.fps
const D = meta.duration

let count = Math.floor(D * fps + 0.5)
if (!meta.loop) count += 1
if (frameArg && frameArg >= 1 && frameArg < count) count = frameArg

const frame = createFrame(W, H, 0, 0)
const fx = createFx(mod, { x: OX, y: OY })

rmSync(outDir, { recursive: true, force: true })
mkdirSync(outDir, { recursive: true })

const out = new Uint8ClampedArray(W * H * 4)
for (let i = 0; i < count; i++) {
    if (i > 0) fx.update(1 / fps)
    clearFrame(frame)
    fx.draw(frame, 'back')
    fx.draw(frame, 'front')
    composite(frame, out, null)
    writeFileSync(path.join(outDir, `f${String(i).padStart(3, '0')}.rgba`), Buffer.from(out.buffer))
}

writeFileSync(
    path.join(outDir, 'meta.json'),
    JSON.stringify({ id, w: W, h: H, frames: count, fps, loop: !!meta.loop, duration: D }, null, 2)
)
console.log(`${id}: ${count} frames ${W}x${H} -> ${outDir}`)
