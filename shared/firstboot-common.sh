#!/bin/sh
# playos-firstboot — Common first-boot logic for PlayOS disk images.
#
# Shared between OpenRC (alpine/init.d/playos-firstboot) and
# systemd (arch/systemd/playos-firstboot.service → ExecStart).
#
# Runs exactly once. Triggered by /etc/playos/firstboot flag file.
#
# Does NOT use OpenRC-specific commands (ebegin/eend/depend).
# Output goes to stdout and /var/log/playos-firstboot.log.
set -eu

LOG="/var/log/playos-firstboot.log"
mkdir -p "$(dirname "$LOG")"

log_msg() {
    local ts
    ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "[$ts] $*" | tee -a "$LOG"
}

log_msg "=== PlayOS first-boot started ==="

# ── 0. Apply pre-flight config from ESP ──────────────────────────────────────
CONFIG_FILE="/boot/efi/playos-install-config"
if [ -f "$CONFIG_FILE" ]; then
    log_msg "Found pre-flight config at $CONFIG_FILE"
    . "$CONFIG_FILE"

    # Hostname
    if [ -n "${cfg_hostname:-}" ]; then
        echo "$cfg_hostname" > /etc/hostname
        hostname "$cfg_hostname" 2>/dev/null || true
        log_msg "Hostname set to: $cfg_hostname"
    fi

    # Timezone
    if [ -n "${cfg_timezone:-}" ] && [ -f "/usr/share/zoneinfo/$cfg_timezone" ]; then
        ln -sf "/usr/share/zoneinfo/$cfg_timezone" /etc/localtime
        log_msg "Timezone set to: $cfg_timezone"
    fi

    # WiFi credentials
    if [ -n "${cfg_wifi_ssid:-}" ] && command -v nmcli >/dev/null 2>&1; then
        for _ in $(seq 1 30); do
            if nmcli -t -f RUNNING general status 2>/dev/null | grep -q 'running'; then
                break
            fi
            sleep 1
        done

        WIFI_DEV="$(nmcli -t -f TYPE,DEVICE device status 2>/dev/null | grep '^wifi:' | cut -d: -f2 | head -1)"
        if [ -n "$WIFI_DEV" ]; then
            CON_NAME="playos-wifi"
            nmcli connection delete "$CON_NAME" 2>/dev/null || true
            if nmcli connection add \
                type wifi \
                ifname "$WIFI_DEV" \
                con-name "$CON_NAME" \
                autoconnect yes \
                ssid "$cfg_wifi_ssid" \
                ${cfg_wifi_psk:+wifi-sec.key-mgmt wpa-psk} \
                ${cfg_wifi_psk:+wifi-sec.psk "$cfg_wifi_psk"} \
                2>/dev/null; then
                nmcli connection up "$CON_NAME" 2>/dev/null && \
                    log_msg "WiFi connected: $cfg_wifi_ssid" || \
                    log_msg "WARNING: WiFi profile created but could not connect"
            fi
        fi
    fi

    # Display name
    if [ -n "${cfg_display_name:-}" ]; then
        mkdir -p /etc/playos
        echo "$cfg_display_name" > /etc/playos/display-name
        log_msg "Display name: $cfg_display_name"
    fi

    # Locale
    if [ -n "${cfg_locale:-}" ]; then
        echo "LANG=$cfg_locale" > /etc/locale.conf
        log_msg "Locale: $cfg_locale"
    fi

    rm -f "$CONFIG_FILE"
    log_msg "Pre-flight config applied"
fi

# ── 0.1 Default timezone ────────────────────────────────────────────────────
if [ ! -L /etc/localtime ] && [ -f /usr/share/zoneinfo/UTC ]; then
    ln -sf /usr/share/zoneinfo/UTC /etc/localtime
    log_msg "Timezone set to UTC (default)"
fi

# ── 1. Regenerate machine-id ─────────────────────────────────────────────────
if command -v uuidgen >/dev/null 2>&1; then
    uuidgen > /etc/machine-id
elif command -v systemd-machine-id-setup >/dev/null 2>&1; then
    systemd-machine-id-setup
else
    dd if=/dev/urandom bs=16 count=1 status=none | od -A n -t x1 | tr -d ' \n' > /etc/machine-id
fi
chmod 444 /etc/machine-id
log_msg "machine-id: $(cat /etc/machine-id)"

# ── 2. Find root, EFI, and data devices ──────────────────────────────────────
ROOT_DEV="$(findmnt -n -o SOURCE /)"
ROOT_DISK=""
EFI_PART=""
DATA_PART=""

case "$ROOT_DEV" in
    /dev/nvme*n*p*)
        ROOT_DISK="$(echo "$ROOT_DEV" | sed 's/p[0-9]*$//')"
        ;;
    /dev/mmcblk*p*)
        ROOT_DISK="$(echo "$ROOT_DEV" | sed 's/p[0-9]*$//')"
        ;;
    /dev/sd*[0-9]|/dev/vd*[0-9])
        ROOT_DISK="$(echo "$ROOT_DEV" | sed 's/[0-9]*$//')"
        ;;
esac

if [ -n "$ROOT_DISK" ]; then
    case "$ROOT_DISK" in
        /dev/nvme*|/dev/mmcblk*) EFI_PART="${ROOT_DISK}p1"; DATA_PART="${ROOT_DISK}p3" ;;
        *)                         EFI_PART="${ROOT_DISK}1";  DATA_PART="${ROOT_DISK}3" ;;
    esac
fi

log_msg "root: $ROOT_DEV  disk: $ROOT_DISK  efi: $EFI_PART  data: $DATA_PART"

# ── 3. Regenerate filesystem UUIDs ───────────────────────────────────────────
if [ -n "$ROOT_DEV" ] && [ -b "$ROOT_DEV" ]; then
    tune2fs -U random "$ROOT_DEV" 2>/dev/null && \
        log_msg "Root UUID regenerated" || log_msg "WARNING: could not regenerate root UUID"
fi

if [ -n "$EFI_PART" ] && [ -b "$EFI_PART" ]; then
    dd if=/dev/urandom of="$EFI_PART" bs=1 count=4 seek=67 conv=notrunc status=none 2>/dev/null && \
        log_msg "EFI volume serial regenerated" || true
fi

if [ -n "$DATA_PART" ] && [ -b "$DATA_PART" ]; then
    tune2fs -U random "$DATA_PART" 2>/dev/null && \
        log_msg "Data UUID regenerated" || log_msg "WARNING: could not regenerate data UUID"
fi

# ── 3b. Resize filesystems ───────────────────────────────────────────────────
if [ -n "$ROOT_DEV" ] && [ -b "$ROOT_DEV" ]; then
    resize2fs -p "$ROOT_DEV" 2>/dev/null && \
        log_msg "Root filesystem resized" || log_msg "Root resize skipped"
fi
if [ -n "$DATA_PART" ] && [ -b "$DATA_PART" ]; then
    resize2fs -p "$DATA_PART" 2>/dev/null && \
        log_msg "Data filesystem resized" || log_msg "WARNING: could not resize data"
fi

# ── 4. Update fstab with new UUIDs ───────────────────────────────────────────
for pair in "$ROOT_DEV:/" "$EFI_PART:/boot/efi" "$DATA_PART:/data"; do
    PART="${pair%%:*}"
    MOUNTPT="${pair##*:}"
    if [ -n "$PART" ] && [ -b "$PART" ]; then
        NEW_UUID="$(blkid -s UUID -o value "$PART" 2>/dev/null || true)"
        if [ -n "$NEW_UUID" ]; then
            sed -i "s|^UUID=[^ ]* $MOUNTPT |UUID=$NEW_UUID $MOUNTPT |" /etc/fstab
        fi
    fi
done

# ── 5. Update boot entry with new root UUID ──────────────────────────────────
NEW_ROOT_UUID="$(blkid -s UUID -o value "$ROOT_DEV" 2>/dev/null || true)"
if [ -n "$NEW_ROOT_UUID" ] && [ -f /boot/efi/loader/entries/playos.conf ]; then
    sed -i "s/root=UUID=[^ ]*/root=UUID=$NEW_ROOT_UUID/" /boot/efi/loader/entries/playos.conf
fi

# ── 6. Create clean EFI boot entry ───────────────────────────────────────────
if [ -d /sys/firmware/efi ] && command -v efibootmgr >/dev/null 2>&1; then
    log_msg "Setting up EFI boot entry..."

    for entry in $(efibootmgr 2>/dev/null | grep -iE 'Fedora|Ubuntu|SteamOS|Pop|Windows|Debian|Limine|PXE|Network' | sed 's/^Boot//;s/\*.*//'); do
        efibootmgr -b "$entry" -B 2>/dev/null && log_msg "Removed stale EFI entry Boot$entry" || true
    done

    LOADER_PATH='\EFI\systemd\systemd-bootx64.efi'
    if [ ! -f /boot/efi/EFI/systemd/systemd-bootx64.efi ]; then
        LOADER_PATH='\EFI\BOOT\BOOTX64.EFI'
    fi

    efibootmgr --create --disk "$ROOT_DISK" --part 1 \
        --label "PlayOS" --loader "$LOADER_PATH" \
        2>/dev/null && log_msg "PlayOS EFI boot entry created" || \
        log_msg "WARNING: could not create EFI boot entry"

    PLAYOS_ENTRY="$(efibootmgr 2>/dev/null | grep -i 'PlayOS' | head -1 | sed 's/^Boot//;s/\*.*//')"
    if [ -n "$PLAYOS_ENTRY" ]; then
        efibootmgr -o "$PLAYOS_ENTRY" 2>/dev/null && \
            log_msg "Boot order set to PlayOS (Boot$PLAYOS_ENTRY)"
    fi
fi

# ── 7. Clean up ──────────────────────────────────────────────────────────────
# Remove symlinks from all possible runlevel directories (OpenRC)
for rl in default boot sysinit playos-visual playos-async; do
    rm -f "/etc/runlevels/$rl/playos-firstboot"
done

# Remove flag file
rm -f /etc/playos/firstboot

log_msg "=== PlayOS first-boot complete ==="
