# SP970 OpenStick 固件变更日志

**版本规则**：MAJOR.MINOR 需项目所有者确认后才可变更；PATCH 由维护者按实际改动递增。

**权威仓**：`antnesswcm/sp970-alpine`

---

## [0.2.0] - 2026-08-29（主线发布）

### 变更
- **主线发布**：v0.2.0 候选实机验证（刷机+扩容+4G+SIM）通过后，dev 合并到 main，tag v0.2.0

---

## [0.1.0] - 2026-08-28

### 新增
- **LED 状态指示**：DTS 配置 + `led-daemon.start` 守护进程，开机自动管理（红心跳→绿心跳）
- **`sp970-link` 链路 CLI**：`card`/`status`/`up` 三子命令，JSON 输出，5 态状态机
- **`sp970-expand-rootfs` 扩容工具**：刷入压缩镜像（~200MB）后，在线扩容到分区大小（~3.47GB）
- **开机自动扩容**：`expand-rootfs.start`，压缩镜像开机自动扩成满分区，免手动扩容

### 变更
- **DTS sim-sel 修正**：`sim_select`(gpio26, ACTIVE_LOW) → `sim-sel`(gpio114, ACTIVE_HIGH, LOW=物理 SIM)
- **rootfs 统一压缩**：所有镜像 `resize2fs -M` 收缩到最小（~200MB），快刷；开机自动扩容补全
- **子模块版本固定**：lk2nd/qtestsign/qhypstub 在 `.gitmodules` 中固定，CI 自动 checkout

### 子模块版本
| 子模块 | Commit |
|---|---|
| lk2nd | 99297666 |
| qtestsign | ce6ba20f |
| qhypstub | fca3c513 |
