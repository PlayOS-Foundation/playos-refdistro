# PlayOS Performance Baseline

- Collected: 2025-02-11T04:04:24Z
- Host: (none) 6.12.103 x86_64
- Model: unknown
- Uptime: 313.70 s

## CPU

    model name	: AMD Ryzen Z1 Extreme
- Cores online: 16
- Loadavg: 0.66 0.42 0.19 1/258 989

## Memory

                  total        used        free      shared  buff/cache   available
    Mem:            260MB used    11118MB free    11100MB avail

## Thermal zones

- acpitz: 43C
- acpitz: 20C

## Power supply

- AC0: status=unknown capacity=?%
- BAT0: status=Full capacity=100%

## Shell FPS (last log lines)

    [   301.553] [INFO] [shell] 55.6 fps (278 frames, 16.7ms/frame)
    [   306.553] [INFO] [shell] 55.6 fps (278 frames, 19.3ms/frame)
    [   311.562] [INFO] [shell] 55.5 fps (278 frames, 16.7ms/frame)

## Boot markers (timestamps are seconds since power-on)

    [         4.565] [init ] playos-init starting as PID 1
    [         6.187] [init ] system ready — entering supervision loop
    [         7.157] [ipc  ] received type=ShellReady from fd=9

## Latencies (log-derived)

    launch→game foreground           2.005 s
    ARMOURY→overlay (IPC)            0.005 s
    game exit→shell                  0.028 s
    boot: init starts at 4.565 s (kernel+firmware before init)

## Idle CPU (5 s sample, % of one core)

    playos-shell (pid 348): 6%
    playos-compositor (pid 312): 4%
    playos-overlay (pid 349): 0%

## Direct scanout

    no 'scanout' lines at the default wlroots log level — not confirmable from logs alone

