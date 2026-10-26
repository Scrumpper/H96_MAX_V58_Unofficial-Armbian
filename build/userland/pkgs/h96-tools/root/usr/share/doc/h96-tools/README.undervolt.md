# Undervolting H96 Max V58 (RK3588)

This box includes tool called `h96-undervolt`. It is **opt-in**: nothing is undervolted
unless you ask for it, and anything you do can be undone.

Read "What this does and does not change" before using it, so your expectations match
what undervolting can affect.

> **Status in v6.0.** Device tree `h96-undervolt` edits is unchanged. Trial flow was
> corrected in v6.0: after `set <mV>` and reboot, setting is active on that boot so you
> can test it under load, and it stays only if you run `confirm`. Reboot without confirming and
> boot-time guard reverts to stock on its own. Every measurement on this page was taken on
> this board and still stands: stock voltages are right ones here, undervolting to
> tool's cap costs 4.4 percent performance to save 1 °C, and overclock direction buys
> +0.53 percent work for +8.7 percent clock. Tool is here so you can check your own chip,
> not because project recommends changing anything.
>
> One v5.0 note that touches this page: box can now be put into flashing mode with
> `reboot loader` over SSH, so recovering from undervolt that boots but misbehaves no
> longer needs pinhole button. Undervolt so low that kernel never starts still
> does, because nothing is running to accept that command. See `FLASHING.md`.

---

## Usage

```bash
sudo h96-undervolt status      # what your chip is set to, and how much room it has
sudo h96-undervolt set 15      # undervolt 15 mV
sudo reboot
sudo h96-undervolt test        # stress it
sudo h96-undervolt confirm     # keep it (otherwise it reverts itself on next boot)
```

To undo at any point:

```bash
sudo h96-undervolt revert && sudo reboot
```

---

## What this does and does not change

Undervolting lowers voltage CPU runs at, which lowers current it draws for
same work. It does not raise maximum board itself can deliver, so treat it as way
to reduce draw and heat rather than as way to gain headroom.

If you want to reduce load-related draw more substantially than undervolting alone can:

1. **Cap CPU frequency.** Lower maximum frequency selects lower stock voltage from
   vendor's table, which reduces draw considerably more than undervolting alone:
   ```bash
   echo 2016000 | sudo tee /sys/devices/system/cpu/cpufreq/policy1/scaling_max_freq \
                           /sys/devices/system/cpu/cpufreq/policy3/scaling_max_freq
   ```
   (not persistent across reboots)
2. Undervolting, as smaller additional reduction on top of above.

---

## Why this is tool and not setting in image

Rockchip measures **every individual chip** during boot. On-die ring oscillator (PVTM)
plus leakage value burned into chip at factory select one of eight voltage bins
(L0 through L7) from table in device tree. You can see yours:

```bash
dmesg | grep pvtm-volt-sel
```

```
cpu cpu1: leakage=8  pvtm=1677  pvtm-volt-sel=4
```

At 2208 MHz vendor's table looks like this:

| Bin          | L0     | L1     | L2     | L3     | L4     | L5     | L6     | L7     |
|--------------|--------|--------|--------|--------|--------|--------|--------|--------|
| Voltage (uV) | 987500 | 975000 | 962500 | 950000 | 962500 | 950000 | 925000 | 912500 |

Chip on **L0 is assigned 987500 uV**. Chip on **L7 is assigned 912500 uV**. That is
75 mV spread between two boxes that look identical on outside.

So there is no single number that could be safely baked into shared image. Publish L7
value and every L0 box becomes unstable in ways its owner would never trace back to
firmware setting. **That is why this is tool that reads your chip, not value someone
else chose for you.**

`h96-undervolt` reads your bin, takes vendor's voltage for *your* bin, and subtracts
your offset from that. Same command produces different voltages on different boxes,
which is point.

---

## How safety net works

**Trial flag.** `set` installs new device tree and arms trial flag. After you reboot,
setting is active on that boot, so you can test it under load. It stays only if you run
`confirm`, which clears flag. Reboot again without confirming and boot-time service
restores stock device tree automatically. So setting that makes your box misbehave undoes
itself after one boot to test it, rather than leaving you with machine that acts strangely for
reasons you have forgotten about. (You can also `confirm` in same session as `set`, before
rebooting, if you already trust value.)

**Hard floor.** Tool refuses to go below lowest voltage Rockchip themselves publish
for that frequency (L7 entry). Rockchip validated that number for their lowest-leakage
silicon. Below it, no value has been validated by anyone.

```
$ sudo h96-undervolt set 200
h96-undervolt: cluster1: 962500 uV - 200 mV = 762500 uV is below the
  vendor floor of 912500 uV for this frequency. Refusing.
  Maximum safe offset for this chip: 50 mV
```

**No compounding.** Every `set` derives from pristine stock backup, never from
already-modified tree. Running `set 10` five times gives you 10 mV, not 50 mV.

**All bins written together.** Whichever bin your kernel selects at boot, it finds same
value, so result never depends on bin selection.

### What safety net cannot do

Auto-revert runs early in userspace. It protects you from *"box boots but is
unstable."* It **cannot** protect you from voltage so low kernel never gets that far.
If that happens box will not boot and you will need to reflash it over USB in Maskrom
mode. Move in small steps (10-15 mV) to stay above that point.

---

## How to test

**Do not trust shell busy-loop.**

```bash
# This is NOT a valid stability test on this board:
for i in $(seq 0 7); do taskset -c $i bash -c 'while :; do :; done' & done
```

Tight integer loop keeps cores busy but exercises narrow part of CPU and draws
less current than application work does. Setting can pass long soak of that loop and
still fail under NEON/SIMD workload at lower temperature. Validating this way will
report setting as stable when it is not.

`h96-undervolt test` runs NEON/SIMD load instead, which is closer to application work.
Even so, it is proxy. Stronger check is full multi-core benchmark run, or using
box under load for several days before relying on setting.

---

## Instability that is not crash

Too-aggressive undervolt does not always announce itself with reboot. It can also cause
**silent miscomputation** - wrong result here and there, corrupted file, build that
fails in inexplicable way. This is worse failure mode than clean crash, because you
may not connect it to voltage change at all.

This is main reason to move in small steps and to revert if anything at all starts
behaving oddly, even if box never resets.

---

## Command reference

| Command                  | What it does                                                                                               |
|--------------------------|------------------------------------------------------------------------------------------------------------|
| `h96-undervolt status`   | Your chip's bin, its vendor voltage, floor, headroom, and whether device tree currently differs from stock |
| `h96-undervolt set <mV>` | Undervolt by `<mV>` below your chip's own vendor value, and arm trial                                      |
| `h96-undervolt test`     | NEON/SIMD stress across all cores (proxy, not proof)                                                       |
| `h96-undervolt confirm`  | Keep current setting; clears auto-revert trial                                                             |
| `h96-undervolt revert`   | Restore vendor voltages                                                                                    |
| `h96-undervolt revert --force` | Restore stock backup although device tree changed outside tool (new kernel DTB) |

`status` and usage text are safe to run as normal user; everything that changes state
requires root.

---

## Files

| Path                                                | Purpose                                          |
|-----------------------------------------------------|--------------------------------------------------|
| `/usr/sbin/h96-undervolt`                     | Tool                                             |
| `/boot/dtb/rockchip/rk3588-h96-max-v58-panthor.dtb` | Active device tree                               |
| `...panthor.dtb.stock-backup`                       | Vendor device tree, kept forever, never modified |
| `/var/lib/h96-undervolt-trial`                      | Present while setting is unconfirmed             |
| `/var/lib/h96-undervolt-state`                      | Offset currently applied                         |
| `h96-undervolt-trial.service`                       | Boot-time auto-revert guard                      |

---

## Kernel switch

`h96-undervolt` writes plain DTB file only. With `h96-kernel-switch` installed:

- `set`, `oc` and `revert` refuse while `/boot/dtb/rockchip/rk3588-h96-max-v58-panthor.dtb` links into kernel
  generation (`h96-kernel-switch dtb` prints `layout=managed`). Generations never change.
  `sudo h96-kernel-switch dtb-plain` turns link back into plain file with same content.
- `set` and `oc` refuse while kernel trial is recorded; `h96-kernel-switch try` refuses while undervolt trial is
  recorded. Boot trials never overlap.
- `h96-kernel-switch try` refuses DTB change while `set` or `oc` change is active: `h96-undervolt revert` first, or
  `try KREL --keep-dtb` keeps modified DTB.
- Device tree differs from stock backup with no change recorded (new kernel DTB): `set` and `oc` refuse, `revert`
  needs `--force`. When current device tree is vendor tree, remove `.stock-backup` file; next `set` backs up current
  device tree.

---

## Overclocking (`h96-undervolt oc`): measured, not recommended

Same tool can go other way and **add** operating point above vendor's 2208 MHz
top. Default `2400 MHz @ 975 mV`; it refuses above 2400 MHz or 1025 mV.

Measured on this board (4 threads pinned to big cores, 3 alternating reps, clock verified
mid-run): **2208 → 3730.5 events/s, 2400 → 3750.2 events/s.** That is **+8.7% clock for +0.53%
work**, with peak temperature 82 °C → 85 °C.

Overclock functions: 2400 MHz was stable at 975 mV and sustained (confirmed by
`time_in_state`: 13442 ticks at 2400 vs 812 at 2208). It does not buy anything, because
bottleneck on RK3588 is memory bandwidth, not core clock.

**If you test one anyway, pin to big cores** (`taskset -c 1,2,3,4`). 8-thread run shows
roughly zero, because four A55s are unchanged and gate total. Note topology is
not contiguous, `policy0` being cpus 0,5,6,7.

**Better use of this headroom is undervolting.** 2400 MHz ran at 975 mV while vendor
assigns 962.5 mV at 2208, so there is room to lower voltage at stock speed for less heat and
power at identical performance.

---

## Measured result: stable to -50 mV, and not worth using

Swept at stock 2208 MHz on correct 12 V supply, each offset applied fresh from stock and
rebooted before testing. **-10, -20, -30, -40 and -50 mV were all stable** (-50 mV is cap
this tool allows for this chip).

But thermally-matched comparison, both runs cooled to 55 °C first with clock pinned and
verified at 2208 MHz:

|        | voltage      | events/s    | end temp |
|--------|--------------|-------------|----------|
| stock  | 962 / 975 mV | **3758.40** | 64 °C    |
| -50 mV | 912 / 925 mV | **3594.62** | 63 °C    |

**4.4% less performance, 1 °C cooler.** That is poor trade, and overclock direction is no
better (+8.7% clock bought +0.53% work). On this box vendor's voltages are correct. Silicon varies, so tool is still here for you to check your own chip, but expect this
result.

Running -5mV to -10mV undervolted *MAY* help when doing anything GPU/NPU intensive. It will gain temp more slowly, possibly keeping temps lower depending on load.

**If you measure it yourself:** `revert` only takes effect after reboot; in
`regulator_summary` voltage is field 6, not field 5; read it under load with clock
pinned, because it tracks current operating point; and cool to matched temperature
between runs, or heat soak will swamp difference.
