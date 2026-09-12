# PlayOS MVP smoke evidence

- Collected: 2025-02-11T04:04:24Z (device clock — may be unset)
- Host: (none) | kernel 6.12.103 x86_64
- Uptime: 313.18 s
- Kernel cmdline: console=tty1 quiet loglevel=3 

## Build identity

    1b8753db19360bf7    177128 bytes  /init
    0a76f93fda056933    325544 bytes  /usr/bin/playos-shell
    0837553f923eb787     55352 bytes  /usr/bin/playos-compositor
    f039410814b74a3e     34648 bytes  /usr/bin/playos-overlay
    46000d67ca670ce9    264048 bytes  /usr/lib/libplayos.so.0.3.0

## Criterion 1/2 — UEFI boot + EFI artifact

    ESP: /dev/nvme0n1p1 on /EFI type vfat (rw,relatime,fmask=0022,dmask=0022,codepage=437,iocharset=utf8,shortname=mixed,errors=remount-ro)
    FOUND /EFI/EFI/BOOT/BOOTX64.EFI (74490880 bytes)
    boot.json: {  "v":1,  "active_slot":"a",  "slot_a":{"version":"0.1.0","boot_count":0,"health":"good"},  "slot_b":{"version":"","boot_count":0,"health":"empty"}}

## Criterion 3 — PID 1 is playos-init

    comm        : init
    exe         : /init
    /sbin/init  : ../bin/busybox
    /init size  : 177128 bytes
    marker      :       playos-init PID 1 Boot Supervisor           

## Criterion 4 — compositor owns DRM/KMS + Wayland

    312 /usr/bin/playos-compositor
    317 /usr/bin/playos-compositor
    srw-rw-rw-    1 root     root             0 Feb 11 03:59 /run/playos/playos-0

## Criterion 5 — shell process

    348 /usr/bin/playos-shell
    [   306.553] [INFO] [shell] 55.6 fps (278 frames, 19.3ms/frame)
    [   311.562] [INFO] [shell] 55.5 fps (278 frames, 16.7ms/frame)

## Criterion 6/12 — GPU: DRM nodes, kernel driver, renderer

    total 0
    drwxr-xr-x    2 root     root            80 Feb 11 03:59 by-path
    crw-rw----    1 root     video     226,   0 Feb 11 03:59 card0
    crw-rw----    1 root     render    226, 128 Feb 11 03:59 renderD128
    drivers: DRIVER=amdgpu
    00:00:00.078 [INFO] [render/gles2/renderer.c:541] GL renderer: AMD Ryzen Z1 Extreme (radeonsi, phoenix, ACO, DRM 3.61, 6.12.103)
    00:00:00.078 [INFO] [render/gles2/renderer.c:542] Supported GLES2 extensions: GL_EXT_blend_minmax GL_EXT_multi_draw_arrays GL_EXT_
    compositor: renderer created, init wl_display...
    compositor: renderer created, querying...

## Criterion 8 — shell links the public libplayos ABI

    lrwxrwxrwx    1 root     root            14 Aug 10  2026 /usr/lib/libplayos.so -> libplayos.so.0
    lrwxrwxrwx    1 root     root            18 Aug 10  2026 /usr/lib/libplayos.so.0 -> libplayos.so.0.3.0
    -rwxr-xr-x    1 root     root        264048 Sep 12  2026 /usr/lib/libplayos.so.0.3.0
    7f21d1edf000-7f21d1ee6000 r--p 00000000 103:02 1411                      /usr/lib/libplayos.so.0.3.0
    7f21d1ee6000-7f21d1eec000 r-xp 00007000 103:02 1411                      /usr/lib/libplayos.so.0.3.0

## Criterion 9 — trusted sockets only

    srw-rw----    1 root     playos-trusted         0 Feb 11 03:59 /run/playos/compositor.sock
    srw-rw----    1 root     playos-trusted         0 Feb 11 03:59 /run/playos/control.sock

## Criterion 10/13/14 — supervision, background/resume

    [        19.438] [sup  ] game backgrounded (SIGSTOP armed in 500ms)
    [        20.439] [sup  ] game 403 SIGSTOP sent (non-cooperative)
    [        22.446] [sup  ] game foregrounded
    [        23.796] [sup  ] game backgrounded (SIGSTOP armed in 500ms)
    [        24.798] [sup  ] game 403 SIGSTOP sent (non-cooperative)
    [        26.806] [sup  ] game foregrounded
    [        34.792] [sup  ] game backgrounded (SIGSTOP armed in 500ms)
    [        35.793] [sup  ] game 403 SIGSTOP sent (non-cooperative)
    [        37.781] [ipc  ] received type=TerminateGame from fd=10
    [        37.781] [ipc  ] TerminateGame: pid=403
    [        37.809] [sup  ] game foregrounded
    [        37.809] [sup  ] game com.playos.sample-bunnymark PID 403 exited: code=-1 signal=15
    --- compositor state transitions ---
    00:00:13.906 [INFO] [/home/nikmes/playos/playos-refdistro/output/ally/build/playos-compositor-0.4.0/src/state_machine.c:101] playos-compositor: foreground GAME_FOREGROUND -> PLAYOS_UI_FOREGROUND_WITH_GAME_BACKGROUND
    00:00:16.849 [INFO] [/home/nikmes/playos/playos-refdistro/output/ally/build/playos-compositor-0.4.0/src/state_machine.c:101] playos-compositor: foreground PLAYOS_UI_FOREGROUND_WITH_GAME_BACKGROUND -> GAME_FOREGROUND
    00:00:18.265 [INFO] [/home/nikmes/playos/playos-refdistro/output/ally/build/playos-compositor-0.4.0/src/state_machine.c:101] playos-compositor: foreground GAME_FOREGROUND -> PLAYOS_UI_FOREGROUND_WITH_GAME_BACKGROUND
    00:00:20.406 [INFO] [/home/nikmes/playos/playos-refdistro/output/ally/build/playos-compositor-0.4.0/src/state_machine.c:101] playos-compositor: foreground PLAYOS_UI_FOREGROUND_WITH_GAME_BACKGROUND -> GAME_FOREGROUND
    00:00:29.261 [INFO] [/home/nikmes/playos/playos-refdistro/output/ally/build/playos-compositor-0.4.0/src/state_machine.c:101] playos-compositor: foreground GAME_FOREGROUND -> PLAYOS_UI_FOREGROUND_WITH_GAME_BACKGROUND
    00:00:32.282 [INFO] [/home/nikmes/playos/playos-refdistro/output/ally/build/playos-compositor-0.4.0/src/state_machine.c:101] playos-compositor: foreground PLAYOS_UI_FOREGROUND_WITH_GAME_BACKGROUND -> SHELL_FOREGROUND

## Criterion 11/12 — gesture + capture evidence

    [    19.433] [INFO] [shell] ARMOURY CRATE tap - showing overlay
    [    23.792] [INFO] [shell] ARMOURY CRATE tap - showing overlay
    [    34.787] [INFO] [shell] ARMOURY CRATE tap - showing overlay
    [    42.148] [INFO] [shell] screenshot requested (COMMAND)
    [    42.148] [INFO] [screencopy] shm buffer format=0x34324258 1920x1080 stride=7680
    [    42.273] [INFO] [shell] screenshot -> /data/screenshots/playos-1739246393.116.png (ok=1)

## Criterion 15 — ALSA devices

    **** List of PLAYBACK Hardware Devices ****
    card 0: Generic [HD-Audio Generic], device 3: HDMI 0 [HDMI 0]
      Subdevices: 1/1
      Subdevice #0: subdevice #0
    card 1: Generic_1 [HD-Audio Generic], device 0: ALC294 Analog [ALC294 Analog]
      Subdevices: 0/1
      Subdevice #0: subdevice #0
    [     7.341] [DEBUG] [input] platform: skip HD-Audio Generic HDMI/DP,pcm=3 (/dev/input/event4): missing gamepad sticks/keys
    INFO: FILEIO: [/data/games/com.playos.sample-audio/assets/icon.png] File loaded successfully
    INFO: FILEIO: [/data/games/com.playos.sample-audio-module/assets/icon.png] File loaded successfully

## Criterion 16 — crash handling

    [        37.809] [sup  ] game com.playos.sample-bunnymark PID 403 exited: code=-1 signal=15

## Criterion 17 — /data is ext4, separate, persistent

    /dev/nvme0n1p5 on /data type ext4 (rw,relatime)
    dirs: cache config downloads games log lost+found playos-boot.txt profiles resources saves screenshots ssh system updates 
    drwxr-xr-x    3 root     root          4096 Feb 11 03:59 .
    drwxr-xr-x   15 root     root          4096 Feb 11 03:59 ..
    drwx------    2 playos-game playos-game      4096 Feb 11 03:59 com.playos.sample-bunnymark
    chosen_data=/dev/nvme0n1p5
    unix_time=1739246356

## Criterion 18 — system image immutable

    /dev/nvme0n1p2 on / type squashfs (ro,relatime,errors=continue)

## Criterion 19 — recovery without accelerated graphics

    recovery marker in logs:
    software render path available? (SimpleDRM/modesetting utilities)
        none — recovery renders through the compositor (SimpleDRM path still TODO: S14-T6 gap, F3)
