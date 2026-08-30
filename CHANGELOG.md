# SP970 OpenStick 固件变更日志

**版本规则**：MAJOR.MINOR 需项目所有者确认后才可变更；PATCH 由维护者按实际改动递增。

**权威仓**：`antnesswcm/sp970-alpine`

---

## [Unreleased]

### 变更
- **开机自动扩容改为"仅首次刷机启动一次"**：`expand-rootfs.start` 不再每次开机按阈值判断重试，
  改为读系统级标记 `/etc/first-boot.done`（存在即跳过）。标记由链路末尾新增的
  `zz-first-boot-done.start` 唯一写入——整条 local.d 链路完整走完才写（含扩容失败场景，
  此后不再重试）；链路中途崩溃/断电则不写、下次开机重试。扩容成败只记
  `/var/log/expand-rootfs.log`，不进入标记。用户手动缩容后标记仍在，开机不会自动扩回；
  手动 `sp970-expand-rootfs` 成功后同样写标记。
- **新增 `zz-first-boot-done.start`（系统级首次启动标记）**：local.d 链路末尾唯一写入者，
  维护 `/etc/first-boot.done`（存在 = 已过首次刷机启动），只维护状态、不评判任何功能成败；
  任何功能判断"是否首次启动"直接读标记存在性，不得自行写标记

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
