# VyOS on the Turris Mox

VyOS rolling on the Turris Mox (Marvell Armada 3720, 1 GiB RAM, SD card only, U-Boot). One hybrid ISO is the only
artifact: write it to the SD card, boot, run `install image`. Updates use `add system image`.

## Prerequisite: current Turris OS firmware

The Mox must run the current firmware (TF-A and U-Boot) that Turris OS ships. It does not update itself with the
operating system, so update it once from Turris OS before writing the VyOS card:

```
opkg update && opkg install turris-nor-update
nor-update
reboot
```

Keep the device powered during the update, recovery from a failed update is difficult. On Turris OS 6.5 and later the
same update is available in reForis under Package Management. Details:
[docs.turris.cz/geek/nor-update/nor-update](https://docs.turris.cz/geek/nor-update/nor-update/).

Tested with the firmware of mox-boot-builder `v2022.06.11` (what the stable `turris-mox-firmware` package ships:
TF-A v2.5, U-Boot 2021.10-rc3) and with `v2024.04.15`. The original factory U-Boot (2018.11) cannot chainload GRUB-EFI
and is not supported. No U-Boot configuration changes are needed; leave `a3720_reset_issue_workaround` unset.

Tested hardware: board version 22, SD-only variant, 8-port Peridot switch module.

## Components

| Part | File |
|---|---|
| Kernel config fragment | `scripts/package-build/linux-kernel/config/arm64/turris-mox.config` |
| mvebu UART registers as `ttyAMA` | `scripts/package-build/linux-kernel/patches/kernel/0008-serial-mvebu-uart-register-as-ttyAMA.patch` |
| Reserve the TF-A memory region (without it PSCI reset and CPU_OFF hang) | `scripts/package-build/linux-kernel/patches/kernel/0009-arm64-reserve-tfa-memory-on-turris-mox.patch` |
| Build flavor | `data/build-flavors/generic-sbc.toml` |
| Hybrid GPT/EFI ISO | `iso_gpt_efi` in `scripts/image-build/build-vyos-image` |
| `install image` behind the live ISO | `data/live-build-config/hooks/live/27-mox-image-installer.chroot` |
| Switch ports excluded from hw-id naming | `data/live-build-config/hooks/live/28-mox-interface-naming.chroot` |
| Default config: DHCP on `eth0`, SSH | `data/live-build-config/hooks/live/29-flavor-default-config.chroot` |
| CI workflow | `.github/workflows/turris-mox-image.yml` |

The hooks use exact string replacements and only act on a Turris Mox (`cznic,turris-mox` in
`/proc/device-tree/compatible`). If upstream changes a patched place, the image build fails on purpose.

## Install

```bash
sudo dd if=vyos-<version>-generic-sbc-arm64.iso of=/dev/sdX bs=4M status=progress conv=fsync
```

Put the card into the Mox and connect `eth0` to a network with a DHCP server. The live system takes an address with
DHCP on `eth0` and has SSH enabled; no serial console is needed. Find the address in the DHCP leases, then:

```
ssh vyos@<address>      # password: vyos
install image           # default answers; the password you enter becomes the password of the user vyos
reboot
```

The installed system keeps the DHCP address on `eth0` and the SSH service, so it is reachable the same way after the
reboot. Serial console (115200 8N1, `ttyAMA0`) works as well, for example to watch the boot.

The installer creates the ESP (256 MB) and the root partition in the free space behind the ISO, installs GRUB without
an NVRAM entry, and removes the ISO partitions when it is done.

Serial console in GRUB and kernel: `set system console device ttyAMA0 speed 115200` and
`set system console device ttyAMA0 kernel` (already part of the default configuration).

The default configuration is for a first installation only: the login `vyos`/`vyos` is valid until `install image`
sets the password, and SSH stays enabled afterwards. Restrict it (`set service ssh ...`, firewall) before connecting
`eth0` to an untrusted network.

## Update

```
add system image http://<host>/vyos-<version>-generic-sbc-arm64.iso
reboot
```

If the flavor differs from the installed one, run the installer with `--force`:
`sudo python3 /usr/libexec/vyos/op_mode/image_installer.py --action add --force --image-path <url>`.

## Build

Build natively on arm64 in the `vyos/vyos-build` container. The Docker Hub image is amd64 only, so build it from this
tree:

```bash
docker build -t vyos/vyos-build:rolling docker
docker run --rm -it --privileged -v $(pwd):/vyos -w /vyos vyos/vyos-build:rolling bash
```

The kernel must come from this tree (the package mirror has no Mox changes). Inside the container:

```bash
cd scripts/package-build/linux-kernel
python3 build.py --packages linux-kernel
cd ../../..
cp scripts/package-build/linux-kernel/linux-image-*-vyos_*_arm64.deb \
   scripts/package-build/linux-kernel/linux-headers-*-vyos_*_arm64.deb packages/
rm -f packages/*-dbg_*
sudo ./build-vyos-image --architecture arm64 --build-by "you@example.com" generic-sbc
```

The result is `build/vyos-<version>-generic-sbc-arm64.iso`. The build log must show the local kernel
(`file:/root/packages ./ linux-image-...`), not a download from `packages.vyos.net`.

`.github/workflows/turris-mox-image.yml` runs the same steps on arm64 runners and uploads the ISO as an artifact.

## Network interfaces

`eth0` and `eth9` are the onboard ports. `eth1`..`eth8` are the switch module ports, pinned by
`/etc/udev/rules.d/71-mox-net-naming.rules` (shipped in the flavor) through their `phys_port_name` (`p1`..`p8`).
`eth9` is the internal CPU port of the switch. `hw-id` entries exist only for `eth0` and `eth9`; the switch ports share
the MAC of `eth9` and must not get one.

```
    +-----------+-----------+-----------+-----------+
    |   eth1    |   eth2    |   eth3    |   eth4    |
    |    p1     |    p2     |    p3     |    p4     |
    +-----------+-----------+-----------+-----------+
    |   eth5    |   eth6    |   eth7    |   eth8    |
    |    p5     |    p6     |    p7     |    p8     |
    +-----------+-----------+-----------+-----------+
```

The layout is schematic; the mapping `ethN` to `pN` is fixed, but whether `pN` matches the silkscreen label of the
module is not verified (plug a cable into port "1" and check `ip -br link`).

## Boot path

`bootcmd=run mox_boot` loads the board device tree from the SPI-NOR flash (offset `0x7f0000`, 64 KiB) and starts the
distro boot. Without `extlinux/extlinux.conf` on the ESP it runs `efi/boot/bootaa64.efi` (GRUB). The SPI device tree
is required: with any other tree U-Boot's board fixup fails (`FDT_ERR_NOTFOUND`). The message `kernel image not
aligned on 64k boundary` is only a warning.

## Notes

- Not tested: SFP, SATA and Mini-PCIe modules (not installed in the tested board), USB3 throughput.
- The system time is wrong on the first boot (no RTC, NTP needs a moment); this causes harmless PAM warnings.
