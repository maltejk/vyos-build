# VyOS rolling on the Turris Mox

**Status: fully working on real hardware.** One hybrid ISO is the only artifact: write it to the SD card with `dd`,
boot, run `install image`, and VyOS runs from the SD card (U-Boot EFI + GRUB, like on x86). Updates use the normal
`add system image`. `reboot` returns to the firmware in about one second.

The Turris Mox (Marvell Armada 3720, dual Cortex-A53, 1 GiB RAM, SD card only, U-Boot) is not an officially supported
VyOS board. Support lives in the `turris-mox-support` branch of this fork and consists of:

| Part | Where |
|---|---|
| Kernel config fragment (Armada 3720, Moxtet, DSA switch drivers) | `scripts/package-build/linux-kernel/config/arm64/turris-mox.config` |
| Kernel patch: mvebu UART is `ttyAMA` | `scripts/package-build/linux-kernel/patches/kernel/0008-serial-mvebu-uart-register-as-ttyAMA.patch` |
| Kernel patch: reserve the TF-A memory (fixes the reboot hang) | `scripts/package-build/linux-kernel/patches/kernel/0009-arm64-reserve-tfa-memory-on-turris-mox.patch` |
| Build flavor `generic-sbc` (ISO, udev rule for the port names) | `data/build-flavors/generic-sbc.toml` |
| Hybrid GPT/EFI ISO (`iso_gpt_efi`) | `scripts/image-build/build-vyos-image` |
| `install image` behind the live ISO on the same SD card | `data/live-build-config/hooks/live/27-mox-image-installer.chroot` |
| Switch ports kept out of the hw-id naming | `data/live-build-config/hooks/live/28-mox-interface-naming.chroot` |
| CI workflow (kernel + ISO on arm64 runners) | `.github/workflows/turris-mox-image.yml` |

The hooks edit installed vyos-1x scripts with exact string replacements and guard every change with a check for the
Turris Mox (`/proc/device-tree/compatible` contains `cznic,turris-mox`). If upstream changes one of the patched
places, the image build fails on purpose. On every other system the scripts behave exactly like upstream.

Tested hardware: Turris Mox board version 22, SD-only variant, 8-port Peridot switch module, official mox-boot-builder
firmware v2024.04.15 (U-Boot 2021.10-rc3 with TF-A and secure firmware).

## Install and update

```bash
# 1. write the ISO to the SD card (it is about 470 MB, the rest of the card stays free for the installation)
sudo dd if=vyos-<version>-generic-sbc-arm64.iso of=/dev/sdX bs=4M status=progress conv=fsync

# 2. put the card into the Mox, connect the serial console (115200 8N1, ttyAMA0), log in as vyos/vyos
install image          # take the default answers
reboot
```

`install image` creates the EFI system partition (256 MB) and the root partition in the free space behind the ISO and
installs GRUB without an NVRAM entry (U-Boot has no writable EFI variables and starts `EFI/BOOT/BOOTAA64.EFI`).
After a successful installation the three GPT entries of the ISO are removed, so that U-Boot finds the new ESP first on
the next boot. The ISO data stay readable for the running live system until then.

Updates:

```
add system image http://<host>/vyos-<version>-generic-sbc-arm64.iso
reboot
```

Configuration and SSH host keys are carried over. GRUB sets `BOOT_IMAGE=` on the kernel command line, which is what
makes the stock `add system image` work (a system booted without it is treated as a live boot). If the image flavor
differs from the installed one the installer refuses; start it with `--force`:
`sudo python3 /usr/libexec/vyos/op_mode/image_installer.py --action add --force --image-path <url>`.

A fresh installation has no SSH service. Enable it on the serial console (`set service ssh`, `commit`, `save`).

Serial console: `ttyAMA0` at 115200 baud. To also get the GRUB menu and kernel messages on the serial line:
`set system console device ttyAMA0 speed 115200` and `... kernel` (VyOS then writes `console_type="ttyAMA"` into the
GRUB defaults). The Mox needs no DIP switch for the SD-only variant; the serial boot documentation is at
[docs.turris.cz/hw/mox/serial-boot](https://docs.turris.cz/hw/mox/serial-boot/).

## Building

The build must run in the `vyos/vyos-build` container, natively on arm64 (a kernel build takes about 15 to 20 minutes
on a 12-core arm64 machine, hours under QEMU emulation). The image on Docker Hub is amd64 only, so build the container
from this tree:

```bash
docker build -t vyos/vyos-build:rolling docker
docker run --rm -it --privileged -v $(pwd):/vyos -w /vyos vyos/vyos-build:rolling bash
```

The kernel has to be built from this tree. The VyOS package mirror ships a kernel without the Mox changes, and the
image build prefers `.deb` files found in `packages/` (`config/packages.chroot` plus pin priority 1001 in
`data/live-build-config/archives/local-packages.pref.chroot`):

```bash
# inside the container
cd scripts/package-build/linux-kernel
python3 build.py --packages linux-kernel
cd ../../..
cp scripts/package-build/linux-kernel/linux-image-*-vyos_*_arm64.deb \
   scripts/package-build/linux-kernel/linux-headers-*-vyos_*_arm64.deb packages/
rm -f packages/*-dbg_*          # the debug package would blow up the image

sudo ./build-vyos-image --architecture arm64 --build-by "you@example.com" generic-sbc
```

Result: `build/vyos-<version>-generic-sbc-arm64.iso` (hybrid: ISO9660 plus GPT with an appended EFI partition). The
build log must show the local kernel being used (`Get: ... file:/root/packages ./ linux-image-...`), not a download
from `packages.vyos.net`. The flavor also lists a `raw` disk image, which is a legacy artifact and no longer needed.

CI: `.github/workflows/turris-mox-image.yml` does the same on `ubuntu-24.04-arm` runners (build container, kernel,
ISO; about 55 + 14 minutes) and uploads the ISO as an artifact. It follows the upstream ISO integration test
(`package-smoketest.yml`) for the mirror and flavor handling. The CLA check workflow is skipped outside the `vyos`
organization.

## How it works

### Kernel configuration

The generic arm64 defconfig had only part of the Armada 3720 support. `vyos_defconfig` enables the platform drivers,
and `turris-mox.config` (merged after the generic fragments by `build-kernel.sh`, arm64 only) adds what the generic
policy files would otherwise switch off:

| Option | Purpose |
|---|---|
| `CONFIG_MVNETA` | onboard Ethernet (without it: no network at all) |
| `CONFIG_SERIAL_MVEBU_UART` | serial console |
| `CONFIG_SPI`, `CONFIG_SPI_ARMADA_3700` | SPI, needed by Moxtet (the whole SPI subsystem was off) |
| `CONFIG_MOXTET` | Mox module bus (switch, SFP, USB3, PCIe, SD modules) |
| `CONFIG_NET_DSA`, `CONFIG_NET_DSA_MV88E6XXX` | LAN switch module (`config/10-networking.config` disables `NET_DSA` and wins if it is merged later) |
| `CONFIG_AHCI_MVEBU`, `CONFIG_USB_XHCI_MVEBU`, `CONFIG_SFP` | SATA module, onboard USB3, SFP cage module |
| `CONFIG_ARMADA_37XX_WATCHDOG` | hardware watchdog |

Already enabled upstream: `ARCH_MVEBU`, `TURRIS_MOX_RWTM`, `MMC_SDHCI_XENON`, `PHY_MVEBU_A3700_COMPHY`,
`PCI_AARDVARK`, `PINCTRL_ARMADA_37XX`, `ARMADA_37XX_CLK`.

### Why a hybrid ISO

The stock `generic` flavor builds an ISO9660 image with an El Torito boot catalog and no partition table. El Torito is a
BIOS/CD-ROM mechanism; the Mox's U-Boot (EFI_LOADER and distro boot) only scans MBR/GPT partition tables for a FAT
partition and ignores El Torito, so a `dd`-ed stock ISO has nothing to boot. With `iso_gpt_efi = true`
`build-vyos-image` rebuilds the ISO with `xorriso`: GPT, an appended EFI system partition (`efi.img`, as Debian does
for arm64) and `-partition_offset 16`. The offset makes partition 1 (`ISO9660`) start exactly at the ISO volume, so the
live system mounts `/dev/mmcblk?p1` and not the whole device. That matters because the kernel refuses `mkfs` and
`mount` on other partitions (`Device or resource busy`) while the whole device is mounted as a filesystem.

### Installing behind the live ISO (hook 27)

`toram` does not work with 1 GiB of RAM (470 MB squashfs plus the VyOS services end in an OOM kill after about four
minutes; with masked daemons no login prompt ever appears). Hook 27 therefore changes `image_installer.py` so that,
only on a Turris Mox and only when the target disk is the disk of the running live medium, the ESP and the root
partition are created in the free space behind the ISO instead of wiping the disk, `grub-install` runs with
`--no-nvram`, and the ISO partitions are removed at the very end.

### Interface naming (hook 28 and the udev rule)

The eight switch ports are DSA user ports. They have no MAC of their own and share the MAC of the CPU port, which is
also the MAC of the onboard `eth9`. The hw-id based naming of recent vyos-1x (`vyos-net-name-resolve.py`,
`vyos-interface-rescan.py`) keys on the MAC and renames ports at random when several interfaces share one
(`eth2` becomes `vyeth5` and the commit ends with `Configuration error`). On a Turris Mox hook 28 therefore

- ignores DSA user ports (devices whose `iflink` differs from their `ifindex`) when discovering NICs and when writing
  hw-id entries into `config.boot`, so hw-id exists only for `eth0` and `eth9`, and
- keeps the names `eth1`..`eth8` reserved in the bootstrap naming (`mox_dsa_port_names()`). Without that, the first boot
  of a fresh installation (no hw-id in the config yet) renamed `eth9` to the "free" name `eth1`; the rename failed,
  `eth9` stayed `vyeth3` and the boot commit failed with `Invalid Ethernet interface name`.

The names themselves are fixed by `/etc/udev/rules.d/71-mox-net-naming.rules` (shipped in the flavor): each switch port
is pinned by its hardware-stable `phys_port_name` (`p1`..`p8`) to `eth1`..`eth8`, and the two onboard mvneta ports are
pinned by their platform device path to `eth0` and `eth9`. The first-boot problem can be reproduced without rewriting
the SD card: `add system image` answering `n` to the config and SSH key copy, with tracing enabled (`vyos-config-debug`
on the kernel command line or `trace_config = True` in `vyos-boot-config-loader.py`; the trace is written to
`/tmp/boot-config-trace`).

Port layout of the 8-port Peridot module as used in the production configuration (every port is an isolated
layer 3 interface with its own /24, no bridge, verified with `arping` and `tcpdump` that there is no cross talk):

```
    +-----------+-----------+-----------+-----------+
    |   eth1    |   eth2    |   eth3    |   eth4    |
    |    p1     |    p2     |    p3     |    p4     |
    | .101.1/24 | .102.1/24 | .103.1/24 | .104.1/24 |
    +-----------+-----------+-----------+-----------+
    |   eth5    |   eth6    |   eth7    |   eth8    |
    |    p5     |    p6     |    p7     |    p8     |
    | .105.1/24 | .106.1/24 | .107.1/24 | .108.1/24 |
    +-----------+-----------+-----------+-----------+
    (all 192.168.10<N>.1/24; "pN" is the phys_port_name pinned by udev)

    CPU/conduit port (DSA internal, not usable externally): eth9
    onboard WAN port (separate from the switch module):     eth0
```

Not verified: whether `p1`..`p8` match the silkscreen labels 1..8 on the module (the 2x4 arrangement above is
schematic). The mapping `ethN` to `pN` is fixed; to find out the printed label, plug a cable into the port marked "1"
and look at which interface gets carrier (`ip -br link`).

## Boot path

U-Boot needs no change. The environment's `bootcmd=run mox_boot` reads the board device tree from the SPI-NOR flash
(`sf read $fdt_addr_r 0x7f0000 0x10000`, 64 KiB, contains `chosen/stdout-path = "serial0:115200n8"` and the
module topology) and then starts the distro boot (`boot_targets=mmc0 usb0 pxe dhcp`). Without an
`extlinux/extlinux.conf` on the ESP, distro boot falls back to `efi/boot/bootaa64.efi` (GRUB-EFI) and passes the SPI
device tree in `fdt_addr_r`. The board device tree is required: U-Boot's `ft_board_setup()` patches module topology,
board version and keys into the tree at every boot, and with a different tree (for example the mainline DTB of the
kernel) it fails with `board-specific fdt fixup failed: FDT_ERR_NOTFOUND`. The message `EFI stub: ERROR: FIRMWARE BUG:
kernel image not aligned on 64k boundary` is only a warning.

GRUB then behaves as on x86: boot menu, `add system image`, `install image`. Kernel arguments written by hand into
GRUB's `vyos-versions/*.cfg` do not persist because VyOS regenerates the file at boot; use the VyOS configuration
(for example `set system console ...`) instead.

## The reboot hang and its root cause

Symptom: `reboot` shut down cleanly, the last console line was `reboot: Restarting system`, then silence, red LED off,
and only a power cycle helped. U-Boot's own `reset` always worked. Also, PSCI `CPU_OFF` (`echo 0 >
/sys/devices/system/cpu/cpu1/online`) froze the whole system.

**Root cause: Linux overwrote the memory of the Trusted Firmware-A (BL31).** BL31 sits in DRAM at `0x4023000` inside the
trusted ROM area `0x4000000`..`0x4400000`. `armada-37xx.dtsi` reserves it as `psci-area@4000000` ("should be updated by
the bootloader"), but the device tree U-Boot passes on the Mox (the SPI-NOR one) has no `reserved-memory` node
(`dmesg`: `No reserved-memory node in the DT`). `/proc/iomem` therefore showed `0x4000000` as ordinary System RAM, the
allocator handed it out, and `/proc/kpageflags` showed 28 of the 29 pages of the BL31 area in use by Linux. PSCI calls
made at boot still work (`CPU_ON` for the second core); later the firmware is corrupted and `SYSTEM_RESET` and
`CPU_OFF` hang. U-Boot's `reset` works because it does not use PSCI and its memory is intact. This also explains why
all firmware experiments failed and why no BL31 debug print ever appeared after a Linux reboot.

**Fix:** kernel patch `0009-arm64-reserve-tfa-memory-on-turris-mox.patch` reserves the 2 MiB at `0x4000000` (reserve
plus nomap) in `arm64_memblock_init()` for `cznic,turris-mox`, as the `psci-area@4000000` node would. Measured on the
board:

- `/proc/iomem`: `04000000-041fffff : reserved`, all BL31 pages reserved.
- `echo 0 > cpu1/online`: `psci: CPU1 killed`, `echo 1` brings the core back (the system froze before).
- PSCI `SYSTEM_RESET` with the watchdog driver unbound (no `/dev/watchdog`): firmware banner 1.0 s after
  `Restarting system`, 2 of 2.
- Normal `reboot` under GRUB-EFI, without any other workaround: banner after 1.0 / 1.0 / 1.2 s (3 of 3), also with a
  CI-built image. U-Boot's EFI `ResetSystem()` is a PSCI call as well, so it works again too.

**The U-Boot variable `a3720_reset_issue_workaround=yes` is not needed.** It switches on a reset workaround in the
secure firmware (WTMI, Cortex-M3) that the watchdog-based workaround used. After removing the variable, power cycling
and measuring again, 3 of 3 reboots took 1.0 to 1.2 s. The official Mox firmware does not set it either (only
`wtmi/soc.c` reads it; no default environment contains it). Leave it unset.

Superseded workarounds, kept for the record: a watchdog restart handler (priority 200, 1 s timeout) in the
`armada_37xx_wdt` driver and a patch skipping `efi_reboot()` on the Mox. Both worked around the symptom and were removed
once the root cause was known. Dead ends on the way: a retry budget in TF-A, BL31 with a bounded console flush and with
the watchdog armed at the start of `psci_system_reset()` (the cause was never in BL31), unloading `turris_mox_rwtm`,
and `efi=noruntime`.

## Verification on real hardware

On a real Turris Mox (board version 22, SD only, 8-port Peridot module), through a USB serial console and SSH:

- Complete cycle: `dd` ISO, live boot, `install image`, reboot from the new ESP, configuration restore, `add system
  image` update, reboot; SSH host key fingerprints unchanged after the update. A fresh installation boots with
  `Configuration success`.
- `dmesg` shows the patched drivers working: both onboard NICs (`mvneta d0030000.ethernet`,
  `mvneta d0040000.ethernet`), `moxtet spi0.1`, `mv88e6085 d0032004.mdio-mii:10: switch 0x1900 detected: Marvell
  88E6190`. `ip -br a` lists `eth0`, `eth1`..`eth8` (switch ports, `eth1@eth9` ... `eth8@eth9`) and `eth9`.
- Watchdog: `/dev/watchdog0`, identity "Armada 37xx Watchdog", 120 s timeout. USB3: `xhci-hcd d0058000.usb: Host
  supports USB 3.0 SuperSpeed`, two xHCI buses (not throughput tested).
- SFP, SATA and Mini-PCIe modules are not installed in the tested board (U-Boot's `printenv` lists only
  `1: Peridot Switch Module (8-port)`); the drivers are enabled but untested.

## Superseded approaches and findings

These were found on the way and are no longer needed with the ISO-only flow; they remain useful if you want to run
another boot path.

- **Factory U-Boot 2018.11** (the original firmware of the board) cannot chainload GRUB-EFI: the arm64 EFI stub aborts
  with `FIRMWARE BUG: efi_loaded_image_t::image_base has bogus value`, sometimes with a CPU exception. The `extlinux`
  path (direct `booti`, no EFI) worked there, with an uncompressed `vmlinuz` (`gunzip -c`; `booti` rejects the gzip
  file with `Bad Linux ARM64 Image magic!`) and the device tree from the SPI-NOR flash (extracted with
  `sf read` and `md.b` over the console; `tftpput` fails with many TFTP servers). With updated firmware (the current
  mox-boot-builder release) GRUB-EFI loads fine; the device tree from the SPI flash is still the one that gets passed
  on (see "Boot path").
- **`system console device ttyMV0`** in `config.boot` makes the whole configuration commit fail (the schema accepts only
  `ttyS*`, `ttyUSB*`, `ttyAMA*`, `hvc*` and similar). The mvebu UART now registers as `ttyAMA` (patch `0008`), so the
  VyOS default `console=ttyAMA0,115200` works unchanged. Finding such errors needs the `vyos-config-debug` kernel
  argument, which writes the Python traceback to `/tmp/boot-config-trace`; without it only `Configuration error` is
  printed.
- **Raw disk image and `mox-sync-boot`.** The flavor still ships `/usr/local/sbin/mox-sync-boot` and can build a `raw`
  image (GPT with ESP and ext4 root, `dd` to the card). That route needs a hand-made `extlinux/extlinux.conf` on the ESP
  and a script that keeps it in sync after `add system image`; it is not needed with GRUB-EFI. To move an old extlinux
  system to GRUB-EFI, rename `extlinux/extlinux.conf` on the ESP (for example to `.off`) and stop using the script.
- **U-Boot watchdog.** Newer U-Boot starts a 60 s hardware watchdog during board init (`WDT: Started watchdog@8300`),
  which resets slow network boots; `wdt dev watchdog@8300` followed by `wdt stop` at the U-Boot prompt prevents that.
  With the Linux watchdog driver unbound, a hung system is rescued by this watchdog after 46 to 108 s.
- **PXE/network boot** works only partly: with a slow USB Ethernet adapter the U-Boot watchdog resets during the
  transfer, and the live system cannot find its root squashfs (needs live-boot's `fetch=` or an NFS root, not
  implemented).
- **Firmware flashing** is done from the U-Boot prompt: `tftpboot` the `a53-firmware.bin` and `sf update 0x20000
  $filesize` (partitions: secure firmware at 0, a53-firmware at `0x20000`, environment at `0x180000`); verify with
  `sf read` and `cmp.b`. Never use `$loadaddr` (undefined in this U-Boot, the arguments shift and the erase fails).
  The `a53-firmware.bin` needs no ECDSA signature, only the secure firmware does.

## Known risks and open points

- The Debian wiki mentions MMC/USB3 dropouts after boot on the Mox with Debian's installer kernel. Not seen here, but
  long-term operation has not been observed.
- The system time is wrong at the first boot (no RTC, NTP needs a moment), which produces harmless PAM warnings
  (`account root has password changed in future`).
- Ideas: fix the missing `reserved-memory` node in U-Boot's device tree fixup (or in `armada-3720-turris-mox.dts`) so
  that no kernel patch is needed; report the `ttyMV0` schema and the DSA/hw-id naming problems to vyos-1x.
