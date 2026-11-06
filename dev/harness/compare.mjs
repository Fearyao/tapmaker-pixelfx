// 逐像素对拍：<js-dir> 与 <lua-dir> 两个裸 RGBA 帧序列比较。
//
// 用法：node scripts/tap-pixelfx/dev/harness/compare.mjs <js-dir> <lua-dir>
// 退出码 0 = 完全一致；1 = 有差异（打印每帧的差异像素数与最大通道差）

import { readFile } from 'node:fs/promises'
import path from 'node:path'

const jsDir = process.argv[2]
const luaDir = process.argv[3]
if (!jsDir || !luaDir) {
    console.error('usage: node compare.mjs <js-dir> <lua-dir>')
    process.exit(2)
}

const jsMeta = JSON.parse(await readFile(path.join(jsDir, 'meta.json'), 'utf8'))
const luaMeta = JSON.parse(await readFile(path.join(luaDir, 'meta.json'), 'utf8'))

if (jsMeta.w !== luaMeta.w || jsMeta.h !== luaMeta.h) {
    console.error(`size mismatch: js ${jsMeta.w}x${jsMeta.h} vs lua ${luaMeta.w}x${luaMeta.h}`)
    process.exit(1)
}
if (jsMeta.frames !== luaMeta.frames) {
    console.error(`frame count mismatch: js ${jsMeta.frames} vs lua ${luaMeta.frames}`)
    process.exit(1)
}

const W = jsMeta.w
const H = jsMeta.h
const total = W * H
let badFrames = 0
let totalPixels = 0

for (let i = 0; i < jsMeta.frames; i++) {
    const name = `f${String(i).padStart(3, '0')}.rgba`
    const a = await readFile(path.join(jsDir, name))
    const b = await readFile(path.join(luaDir, name))
    let diff = 0
    let maxDelta = 0
    for (let p = 0; p < total; p++) {
        const o = p * 4
        const d0 = Math.abs(a[o] - b[o])
        const d1 = Math.abs(a[o + 1] - b[o + 1])
        const d2 = Math.abs(a[o + 2] - b[o + 2])
        const d3 = Math.abs(a[o + 3] - b[o + 3])
        const d = Math.max(d0, d1, d2, d3)
        if (d !== 0) {
            diff++
            if (d > maxDelta) maxDelta = d
        }
    }
    totalPixels += diff
    if (diff !== 0) {
        badFrames++
        const pct = ((diff / total) * 100).toFixed(2)
        console.log(`frame ${i}: ${diff} px differ (${pct}%), max channel delta ${maxDelta}`)
    }
}

const ok = badFrames === 0
console.log(
    `${ok ? 'MATCH' : 'DIFF'}: ${jsMeta.frames - badFrames}/${jsMeta.frames} frames identical` +
        (ok ? '' : `, ${totalPixels} differing pixels total`)
)
process.exit(ok ? 0 : 1)
