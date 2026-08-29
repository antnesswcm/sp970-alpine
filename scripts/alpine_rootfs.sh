#!/bin/sh -e

export CHROOT=${CHROOT=$(pwd)/rootfs}
export HOST_NAME=${HOST_NAME=openstick-alpine}
export RELEASE=${RELEASE=v3.24}
export PMOS_RELEASE=${PMOS_RELEASE=v25.12}
export MIRROR=${MIRROR=http://dl-cdn.alpinelinux.org/alpine}
export PMOS_MIRROR=${PMOS_MIRROR=http://mirror.postmarketos.org/postmarketos}
export APK_STATIC_URL=https://gitlab.alpinelinux.org/api/v4/projects/5/packages/generic/v3.0.6/x86_64/apk.static

rm -rf ${CHROOT}

mkdir -p ${CHROOT}/etc/apk
cat << EOF >  ${CHROOT}/etc/apk/repositories
${MIRROR}/${RELEASE}/main
${MIRROR}/${RELEASE}/community
@pmos ${PMOS_MIRROR}/${PMOS_RELEASE}
EOF

cp /etc/resolv.conf ${CHROOT}/etc/

mkdir -p ${CHROOT}/usr/bin
cp $(which qemu-aarch64-static) ${CHROOT}/usr/bin

# apk.static committed to repo (scripts/apk.static) for CI reliability.
# Avoids flaky download from gitlab.alpinelinux.org on GitHub runners.
cp scripts/apk.static apk.static
chmod a+x apk.static

./apk.static add -p ${CHROOT} --initdb -U --arch aarch64 --allow-untrusted alpine-base

# install apps
chroot ${CHROOT} ash -l -c "
apk add --allow-untrusted postmarketos-keys@pmos
apk add \
    bridge-utils \
    chrony \
    dropbear \
    dbus \
    e2fsprogs-extra \
    eudev \
    gadget-tool \
    iptables \
    linux-postmarketos-qcom-msm8916@pmos \
    modemmanager \
    msm-firmware-loader@pmos \
    qmi-utils \
    openrc \
    rmtfs \
    shadow \
    sudo \
    udev-init-scripts \
    udev-init-scripts-openrc \
    wireguard-tools \
    wireguard-tools-wg-quick \
    wireless-regdb \
    iw

# clear
rm /etc/fstab
"

# extract NetworkManager from previous alpine version (v3.20)
scripts/extract_networkmanager.sh

# setup alpine
chroot ${CHROOT} ash -l -c "
echo user:1::::/home/user:/bin/ash | newusers

# update users used by chrooted apps
addgroup -S dnsmasq
adduser -S -D -H -h /dev/null -s /sbin/nologin -G dnsmasq -g dnsmasq dnsmasq

# sync
ln /etc/group    /usr/local/etc
ln /etc/passwd   /usr/local/etc
ln /etc/hostname /usr/local/etc

ln -sf /usr/local/etc/resolv.conf /etc

# add symlinks
for a in nm-online nmcli nmtui nmtui-connect nmtui-edit nmtui-hostname; do
    ln -s /usr/local/bin/chroot.sh /usr/bin/\${a};
done

rc-update add devfs sysinit
rc-update add dmesg sysinit
rc-update add udev sysinit
rc-update add udev-trigger sysinit
rc-update add udev-settle sysinit
rc-update add udev-postmount default
rc-update add hwclock boot
rc-update add modules boot
rc-update add sysctl boot
rc-update add hostname boot
rc-update add bootmisc boot
rc-update add mount-ro shutdown
rc-update add killprocs shutdown
rc-update add savecache shutdown
# dbus + polkit MUST be in the boot runlevel: modemmanager needs polkit, and with
# MM not auto-started (Plan B) nothing else pulls polkit in, so MM would fail
# with: cannot start modemmanager as polkit would not start (verified 2026-08-26).
rc-update add dbus default
rc-update add polkit default
rc-update add dropbear default
rc-update add rmtfs default
# NOTE: ModemManager is intentionally NOT added to boot (Plan B).
# - MM at boot mis-detects sim-missing (N958St Get Slot Status NotSupported) and
#   power-offs the modem. We let the modem boot unmanaged, activate the SIM via
#   qmicli (sim-activate.start), then start MM once the SIM is registered.
# - D-Bus activation is disabled too (see below), else NetworkManager probing
#   would auto-launch MM via org.freedesktop.ModemManager1.service.
rc-update add networkmanager default
rc-update add networkmanager-dispatcher default
rc-update add wpa_supplicant default
rc-update add local default
"

# ===== Everything below runs on the build host (outside the chroot) =====
# The local.d scripts and D-Bus edits MUST be outside the chroot "..." block:
# inside a double-quoted chroot block, shell would expand $VAR / $(...) in the
# heredocs and corrupt the scripts. Using ${CHROOT} paths directly avoids that.

# NOTE: rootfs sizing done at build time (build_images.sh resize2fs -M shrink to ~200MB),
# 开机由 expand-rootfs.start 自动扩成满分区（阈值 95%，日志 /var/log/expand-rootfs.log）。
mkdir -p ${CHROOT}/etc/local.d

# SIM activation (Plan B) + modem bring-up + NAT.
# Root cause: N958St modem UIM Get Slot Status returns NotSupported, so MM at
# boot always mis-reports "sim-missing" and power-offs the modem. Instead:
#   - MM is NOT auto-started and its D-Bus activation is disabled, so it never
#     touches the modem during boot;
#   - sim-activate.start: waits for QMI port, discovers USIM AID, provisions,
#     enables RF (CFUN=1), pushes registration, then starts MM.
# After MM starts, MM + NetworkManager auto-create the data bearer and
# configure IP/route/DNS (verified). No manual IP config needed.
cp scripts/local.d/sim-activate.start ${CHROOT}/etc/local.d/sim-activate.start
chmod +x ${CHROOT}/etc/local.d/sim-activate.start

# Disable MM D-Bus activation: without this, NetworkManager probing the
# org.freedesktop.ModemManager1 name would auto-launch MM even though it is not
# in the boot runlevel, re-introducing the sim-missing power-off problem.
sed -i 's|Exec=/usr/sbin/ModemManager|Exec=/bin/false|' \
    ${CHROOT}/usr/share/dbus-1/system-services/org.freedesktop.ModemManager1.service 2>/dev/null || true

# Plan A: make /etc/init.d/local depend on dbus/polkit, so its local.d scripts
# (sim-activate) run only after dbus+polkit are up. ModemManager (needs both)
# then starts cleanly in a single rc-service call - no retry hammering.
# 'after *' already exists in the local service; we add explicit dbus/polkit.
sed -i '/^[[:space:]]*after \*/a\\tafter dbus polkit' \
    ${CHROOT}/etc/init.d/local 2>/dev/null || true

# WiFi(192.168.4.x) -> 4G(wwan0) NAT forwarding
cp scripts/local.d/nat.start ${CHROOT}/etc/local.d/nat.start
chmod +x ${CHROOT}/etc/local.d/nat.start

# LED daemon (first version: one-shot, shell, zero deps)  [v5]
# local.d runs *.start in alphabetical (glob) order: led-daemon < nat < sim-activate,
# so this runs FIRST. That is fine: it only sets LED triggers (red off, green
# heartbeat) and waits for sysfs; it does not depend on sim-activate. The visual
# effect is: red heartbeat (DTS) -> green heartbeat (this) early in boot, before
# networking is fully up. Acceptable for v1.
# LED daemon (v5: one-shot, shell, zero deps)
# local.d runs *.start in alphabetical order: led-daemon < nat < sim-activate.
# Sets LED triggers (red off, green heartbeat); blue phy0tx kept from DTS.
cp scripts/local.d/led-daemon.start ${CHROOT}/etc/local.d/led-daemon.start
chmod +x ${CHROOT}/etc/local.d/led-daemon.start

# Rootfs 开机自动扩容（压缩镜像 -> 满分区）
# local.d 按字母序执行：expand-rootfs < led-daemon < nat < sim-activate
# 所以这个最先跑。压缩镜像 (~200MB) 开机自动扩成满分区 (~3.47GB)。
# 已扩容时 no-op 跳过（CUR_SIZE >= PART_SIZE*95%）。日志：/var/log/expand-rootfs.log
cp scripts/local.d/expand-rootfs.start ${CHROOT}/etc/local.d/expand-rootfs.start
chmod +x ${CHROOT}/etc/local.d/expand-rootfs.start

echo 'user ALL=(ALL:ALL) NOPASSWD: ALL' > ${CHROOT}/etc/sudoers.d/user

# add udev rules
cat << EOF > ${CHROOT}/etc/udev/rules.d/10-udc.rules
ACTION=="add", SUBSYSTEM=="udc", RUN+="/sbin/modprobe libcomposite", RUN+="/usr/local/bin/setup_ncm_gadget.sh"
EOF

cat << EOF > ${CHROOT}/etc/udev/rules.d/99-nm-usb0.rules
SUBSYSTEM=="net", ACTION=="add|change|move", ENV{DEVTYPE}=="gadget", ENV{NM_UNMANAGED}="0"
EOF

# enable autologin on console
sed -i '/^tty/ s/^/#/' ${CHROOT}/etc/inittab
echo 'ttyMSM0::respawn:/bin/sh' >> ${CHROOT}/etc/inittab

echo ${HOST_NAME} > ${CHROOT}/etc/hostname
sed -i "/localhost/ s/$/ ${HOST_NAME}/" ${CHROOT}/etc/hosts

# setup NetworkManager
cp configs/*.nmconnection ${CHROOT}/usr/local/etc/NetworkManager/system-connections
chmod 0600 ${CHROOT}/usr/local/etc/NetworkManager/system-connections/*
ln -s ../usr/local/etc/NetworkManager ${CHROOT}/etc/NetworkManager

mkdir -p ${CHROOT}/boot/extlinux
cp configs/extlinux.conf ${CHROOT}/boot/extlinux

# copy custom dtb's
cp dtbs/* ${CHROOT}/boot/dtbs/qcom

# copy WCNSS firmware and NV calibration (SP970)
# Proprietary blobs committed to firmware/<board>/ for self-contained build.
# Source: stock firmware (NON-HLOS.bin + persist partition).
if [ -d firmware/sp970 ]; then
    mkdir -p ${CHROOT}/lib/firmware/wlan/prima
    for f in firmware/sp970/WCNSS.B* firmware/sp970/WCNSS.MDT; do
        [ -e "$f" ] || continue
        # lower-case filename (wcnss.b00 ... wcnss.mdt) as expected by wcnss-pil
        name=$(basename "$f" | tr 'A-Z' 'a-z')
        cp "$f" ${CHROOT}/lib/firmware/$name
    done
    # NV calibration -> /lib/firmware/wlan/prima/
    [ -e firmware/sp970/WCNSS_qcom_wlan_nv.bin ] && \
        cp firmware/sp970/WCNSS_qcom_wlan_nv.bin ${CHROOT}/lib/firmware/wlan/prima/
fi

# copy modem firmware (SP970) to /lib/firmware/
# mss-pil loads mba.mbn, then modem.mdt (with modem.bXX segments).
# Without these the modem remoteproc stays offline (Boot failed: -2).
if [ -d firmware/modem/sp970 ]; then
    mkdir -p ${CHROOT}/lib/firmware
    cp firmware/modem/sp970/mba.mbn ${CHROOT}/lib/firmware/
    cp firmware/modem/sp970/modem.mbn ${CHROOT}/lib/firmware/
    cp firmware/modem/sp970/modem.mdt ${CHROOT}/lib/firmware/
    cp firmware/modem/sp970/modem.b* ${CHROOT}/lib/firmware/
fi

# update fstab
echo "/dev/mmcblk0p14\t/boot\text2\tdefaults\t0 2" >> ${CHROOT}/etc/fstab

# copy gadget-tool templates and script
cp -a configs/templates ${CHROOT}/etc/gt
cp scripts/setup_ncm_gadget.sh ${CHROOT}/usr/local/bin/setup_ncm_gadget.sh
chmod +x ${CHROOT}/usr/local/bin/setup_ncm_gadget.sh

# sp970-link: modem link status/control interface (card|status|up, JSON)  [v5]
# /usr/local/bin (canonical) + /usr/bin symlink so it is callable from the
# default non-login PATH (dropbear exec / cron / future services).
cp scripts/sp970-link ${CHROOT}/usr/local/bin/sp970-link
chmod +x ${CHROOT}/usr/local/bin/sp970-link
ln -sf /usr/local/bin/sp970-link ${CHROOT}/usr/bin/sp970-link

# sp970-expand-rootfs: rootfs 在线扩容工具（压缩镜像 -> 满分区）
# 所有镜像都收缩到最小 (~200MB)，开机由 expand-rootfs.start 自动扩容。
# 此工具供用户检查/手动扩容：df -h 全景 + 已扩容跳过 + --check。
# Requires e2fsprogs-extra (resize2fs) which is installed above.
cp scripts/sp970-expand-rootfs ${CHROOT}/usr/local/bin/sp970-expand-rootfs
chmod +x ${CHROOT}/usr/local/bin/sp970-expand-rootfs
ln -sf /usr/local/bin/sp970-expand-rootfs ${CHROOT}/usr/bin/sp970-expand-rootfs

# write firmware version identifier for quick boot-time identification
# /etc/openstick-version: "v4.0.0 (2026-08-25, commit ff25894c1a2b...)"  [full hash for exact verification]
# /etc/openstick-changelog.md: 随固件打包的变更日志
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIRMWARE_VERSION="$(cat "${REPO_ROOT}/VERSION" 2>/dev/null || echo 0.0.0)"
FIRMWARE_HASH="$(git -C "${REPO_ROOT}" rev-parse HEAD 2>/dev/null || echo unknown)"
FIRMWARE_HASH_SHORT="$(git -C "${REPO_ROOT}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
FIRMWARE_DATE="$(date +%Y-%m-%d)"
echo "v${FIRMWARE_VERSION} (${FIRMWARE_DATE}, commit ${FIRMWARE_HASH_SHORT} ${FIRMWARE_HASH})" \
    > ${CHROOT}/etc/openstick-version
chmod 644 ${CHROOT}/etc/openstick-version
# include changelog in firmware (if present in repo)
if [ -f "${REPO_ROOT}/CHANGELOG.md" ]; then
    cp "${REPO_ROOT}/CHANGELOG.md" ${CHROOT}/etc/openstick-changelog.md
    chmod 644 ${CHROOT}/etc/openstick-changelog.md
fi

# ---- firmware integrity check (build time gate) ----
# Verify that all critical files exist in the rootfs before packaging.
# Any missing file → exit 1 (build fails, no bad firmware).
echo "=== firmware integrity check ==="
errors=0
check() {
    if [ -e "${CHROOT}/$1" ]; then
        echo "  ✅ $1"
    else
        echo "  ❌ $1 — MISSING!"
        errors=$((errors+1))
    fi
}

check "etc/local.d/sim-activate.start"
check "etc/local.d/nat.start"
check "etc/local.d/led-daemon.start"
check "usr/local/bin/sp970-link"
# usr/bin/sp970-link is a symlink to /usr/local/bin/sp970-link.
# -e follows symlinks and resolves the absolute target on the BUILD HOST
# (not inside the chroot) → false MISSING. Use -L to check the link itself.
if [ -L "${CHROOT}/usr/bin/sp970-link" ]; then
    echo "  ✅ usr/bin/sp970-link (symlink)"
else
    echo "  ❌ usr/bin/sp970-link — symlink MISSING!"
    errors=$((errors+1))
fi
check "boot/vmlinuz"
check "boot/extlinux/extlinux.conf"
check "boot/dtbs/qcom/msm8916-handsome-openstick-sp970.dtb"
check "lib/firmware/mba.mbn"
check "lib/firmware/modem.mdt"
check "lib/firmware/wcnss.b00"
check "etc/openstick-version"
check "etc/openstick-changelog.md"

# Verfiy local.d scripts are not empty (heredoc truncation check)
for f in sim-activate.start nat.start led-daemon.start; do
    fpath="${CHROOT}/etc/local.d/$f"
    if [ -s "$fpath" ]; then
        # check at least 5 lines (not a truncated heredoc)
        lines=$(wc -l < "$fpath")
        if [ "$lines" -lt 5 ]; then
            echo "  ❌ etc/local.d/$f — too short ($lines lines), possible heredoc truncation!"
            errors=$((errors+1))
        fi
    fi
done

if [ "$errors" -gt 0 ]; then
    echo "❌ firmware integrity check: $errors errors — aborting build"
    exit 1
fi
echo "✅ firmware integrity check: all files present"

# ---- executable permission check (build time gate) ----
# Verify all scripts that need to be executed have +x permission.
# Missing +x = silent failure at runtime (udev can't run the script).
echo "=== executable permission check ==="
perm_errors=0
check_exec() {
    local f="$1"
    if [ -x "${CHROOT}/${f}" ]; then
        echo "  ✅ ${f} (executable)"
    else
        echo "  ❌ ${f} — NOT executable!"
        perm_errors=$((perm_errors+1))
    fi
}

# /usr/local/bin scripts (called by udev, cron, services)
check_exec "usr/local/bin/setup_ncm_gadget.sh"
check_exec "usr/local/bin/sp970-link"
check_exec "usr/local/bin/sp970-expand-rootfs"

# /etc/local.d startup scripts (called by local init)
for f in expand-rootfs.start sim-activate.start nat.start led-daemon.start; do
    check_exec "etc/local.d/${f}"
done

if [ "$perm_errors" -gt 0 ]; then
    echo "❌ executable permission check: $perm_errors errors — aborting build"
    exit 1
fi
echo "✅ executable permission check: all scripts executable"

# backup rootfs
rm -f alpine_rootfs.tgz
tar cpzf alpine_rootfs.tgz \
    --exclude="root/*" \
    --exclude="newroot" \
    --exclude="usr/bin/qemu-aarch64-static" \
    -C rootfs .
