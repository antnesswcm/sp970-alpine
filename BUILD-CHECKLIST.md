# SP970 固件构建与测试 Checklist

> 防止遗漏。每次构建/修改前必读，逐项打勾。

## 构建前 Checklist

### 1. 脚本权限
- [ ] 所有 `/usr/local/bin/*.sh` 有 `chmod +x`
- [ ] 所有 `/etc/local.d/*.start` 有 `chmod +x`
- [ ] `alpine_rootfs.sh` 中复制脚本后都有 `chmod +x`

### 2. udev 规则
- [ ] `10-udc.rules` 存在（NCM 自动启动）
- [ ] `99-nm-usb0.rules` 存在（NetworkManager 管理）
- [ ] 规则引用的脚本路径正确且有执行权限

### 3. 开机服务
- [ ] `local.d/*.start` 按字母序排列正确
- [ ] 新脚本命名不影响执行顺序

### 4. 依赖包
- [ ] `alpine_rootfs.sh` 中包列表完整
- [ ] 新工具需要的包已添加（如 `e2fsprogs-extra`）

### 5. 首次启动标记机制（`zz-first-boot-done.start`）
- [ ] 必须以 `zz-` 前缀命名，字母序排在所有 local.d 脚本**最后**（链路末尾才写标记）
- [ ] 职责边界：链路末尾写 `/etc/first-boot.done`，**只标记不评判**（各功能成败只进各自日志），幂等（标记已存在即退出）
- [ ] 消费约定：其他脚本判断"是否首次启动"只读标记存在性，**不得自行写标记**（唯一例外：手动 `sp970-expand-rootfs` 扩容成功后写）

## 构建后 Checklist

### 1. 构建产物
- [ ] `openstick-alpine.zip` 生成成功
- [ ] 8 个镜像文件完整（aboot/hyp/rpm/sbl1/tz/boot/rootfs/gpt）

### 2. 离线验证
- [ ] 解包 `alpine_rootfs.bin` 检查关键路径
- [ ] 验证脚本权限（`ls -la` 检查 +x）
- [ ] 验证 udev 规则存在
- [ ] 验证 local.d 脚本非空

## 刷机后 Checklist

### 1. 基础功能
- [ ] 设备开机成功（SSH 可达）
- [ ] WiFi 热点正常（`192.168.4.1`）
- [ ] 4G 链路正常（`sp970-link status`）
- [ ] SIM 卡状态正常（`sp970-link card`）

### 2. USB NCM
- [ ] USB 插入 PC 后自动识别
- [ ] NCM 网络接口出现（`usb0` 或 `ncm0`）
- [ ] `setup_ncm_gadget.sh` 有执行权限（`ls -la`）

### 3. 工具
- [ ] `sp970-link` 可执行
- [ ] `sp970-expand-rootfs -y` 可执行
- [ ] 磁盘空间正常（已扩容到分区大小，`sp970-expand-rootfs --check` 确认）
- [ ] 首次启动标记已写（`cat /etc/first-boot.done`，链路末尾 `zz-first-boot-done.start` 已执行）

### 4. 日志
- [ ] 无致命错误（`dmesg | grep -i error`）
- [ ] udev 规则触发正常（`dmesg | grep -i udc`）

## 常见问题排查

### NCM 不自动启动
1. 检查 `setup_ncm_gadget.sh` 权限：`ls -la /usr/local/bin/setup_ncm_gadget.sh`
2. 检查 udev 规则：`cat /etc/udev/rules.d/10-udc.rules`
3. 检查 UDC 设备：`ls /sys/class/udc/`
4. 手动运行测试：`sudo /usr/local/bin/setup_ncm_gadget.sh`

### 脚本执行失败
1. 检查权限：`ls -la <script>`
2. 检查 shebang：`head -1 <script>`
3. 检查依赖：`which <command>`

**原则**：构建时检查，不要等运行时失败。