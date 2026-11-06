# Notices

本库是 [pixelfx](https://patch-gg.github.io/pixelfx/) 的 **Lua 5.4 移植 + UrhoX/TapMaker 运行时**，
不是独立原创实现。上游 pixelfx 采用 MIT 许可（Copyright (c) 2026 Patch / Hugo Duprez），
本库沿用同一许可，见 `LICENSE`。

## 上游

- pixelfx：<https://github.com/patch-gg/pixelfx>（MIT）
- pixelfx 的 `src/core/sim.js` 及部分特效改编自 Hugo Duprez 的 Sprite Fusion 开源像素 VFX
  （<https://www.spritefusion.com/pixel-art-vfx>，MIT，Copyright (c) 2026 Hugo Duprez）。

## 本库范围

- `core/`：上游 `src/core/{color,painter,font,math,particles,sim,shapes}.js` 与
  `src/fx/critters/_lib.js` 的 `Grid` 的 Lua 移植。
- `effects/`：逐个特效从上游 `src/fx/<category>/<name>.js` 移植，每个文件头都写明了原版路径；
  移植版的验收标准是与原版**逐像素一致**（`dev/harness` 里的对拍台）。
- `runtime/`、`init.lua`、`dev/`、`atlas/`：本库新增（图集由本库的 Lua 代码在构建期烤出）。

## 未包含的上游部分

`act.js` / `rig.js`（角色骨骼与动作时间轴）、`scene.js`（背景板）、`gallery/` 及其字体
（上游明确声明字体不在 MIT 覆盖范围内）。需要这些能力请直接引用上游仓库。
