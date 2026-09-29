# VyOS rolling auf Turris Mox

Turris Mox (Marvell Armada 3720, dual Cortex-A53) ist kein offiziell
unterstütztes VyOS-Board. VyOS baut aber ein generisches arm64-Image
(`generic` flavor), das auf jeder Plattform läuft, deren Treiber im Kernel
aktiv sind. Armada-3720-Support war im VyOS-Kernel-Defconfig nur teilweise
aktiv — gefixt in `scripts/package-build/linux-kernel/config/arm64/vyos_defconfig`.

## Was gefixt wurde (Kernel-Config)

Datei: `scripts/package-build/linux-kernel/config/arm64/vyos_defconfig`

| Option | Vorher | Nachher | Wofür |
|---|---|---|---|
| `CONFIG_MVNETA` | aus | `m` | Onboard-Ethernet (WAN-Port) — ohne das: kein Netzwerk überhaupt |
| `CONFIG_SERIAL_MVEBU_UART` | aus | `y` | Serial-Konsole (UART-Pins) — ohne das: keine Konsole beim Boot |
| `CONFIG_MOXTET` | fehlte | `m` | Mox-Modulbus (erkennt LAN-Switch-/SFP-/USB3-/PCI-/SD-Modul) |
| `CONFIG_NET_DSA` + `CONFIG_NET_DSA_MV88E6XXX` | fehlten | `m` | 4-/8-Port-LAN-Switch-Modul (falls vorhanden) |
| `CONFIG_AHCI_MVEBU` | aus | `m` | SATA-Modul (falls vorhanden) |
| `CONFIG_USB_XHCI_MVEBU` | aus | `m` | Onboard-USB3 |
| `CONFIG_ARMADA_37XX_WATCHDOG` | aus | `m` | Hardware-Watchdog |
| `CONFIG_SFP` | aus | `m` | SFP-Käfig-Modul (falls vorhanden) |

Bereits vorher aktiv (nicht angefasst): `CONFIG_ARCH_MVEBU`, `CONFIG_TURRIS_MOX_RWTM`
(Board-Info/RNG über Secure-Firmware), `CONFIG_MMC_SDHCI_XENON` (eMMC/SD),
`CONFIG_PHY_MVEBU_A3700_COMPHY` (USB3/PCIe/SATA-PHY-Mux), `CONFIG_PCI_AARDVARK`
(Mini-PCIe-Slot), `CONFIG_PINCTRL_ARMADA_37XX`, `CONFIG_ARMADA_37XX_CLK`.

**Nachgezogener Fix:** der erste Build zeigte, dass `CONFIG_MOXTET` und
`CONFIG_NET_DSA_MV88E6XXX` trotz obiger Tabelle NICHT im fertigen Kernel
landeten — zwei Gründe: `CONFIG_SPI` (das gesamte SPI-Subsystem) war im
arm64-Defconfig komplett aus, und `MOXTET` braucht `SPI_MASTER`; außerdem
schaltet die architekturübergreifende Datei `config/10-networking.config`
`CONFIG_NET_DSA` explizit wieder aus und gewinnt, weil sie nach dem
arch-Defconfig gemergt wird. Fix: neue Datei
`scripts/package-build/linux-kernel/config/arm64/turris-mox.config`
mit `CONFIG_SPI=y`, `CONFIG_SPI_ARMADA_3700=m`, `CONFIG_MOXTET=m`,
`CONFIG_NET_DSA=m`, `CONFIG_NET_DSA_MV88E6XXX=m`, die laut
`build-kernel.sh` erst NACH den generischen `config/*.config`-Fragmenten
gemergt wird (arm64-only, rührt die geteilte amd64/arm64-Policy-Datei nicht
an). Im gebauten Kernel verifiziert (`/boot/config-6.18.50-vyos` aus dem
`.deb` extrahiert) — alle Optionen korrekt drin.

## Image-Format — ISO funktioniert NICHT, `.raw` schon

Die Standard-`generic`-Flavor von VyOS baut ein ISO9660-Image mit
El-Torito-Bootcatalog **ohne jede Partitionstabelle** (mit `gdisk -l`
nachgeprüft: weder MBR noch GPT vorhanden). El Torito ist ein reiner
BIOS/CD-ROM-Mechanismus — Mox' mainline U-Boot (EFI_LOADER + Distro-Boot)
scannt nur GPT/MBR-Partitionstabellen nach einer FAT-ESP und kennt El Torito
nicht. Das ISO auf eine SD-Karte gedd't, hat U-Boot schlicht nichts zum
Booten. (Genau das beschreibt auch das Debian-Wiki: "The standard ISO
installation method is not compatible" für Mox.)

Fix: neue Build-Flavor `data/build-flavors/generic-raw.toml`
mit `image_format = ["iso", "raw"]`. Das nutzt VyOS' vorhandene
`raw_image.create_raw_image()`-Pipeline (dieselbe wie für Cloud-Images) und
erzeugt zusätzlich eine `.raw`-Datei mit echtem GPT: BIOS-Boot-Partition
(unbenutzt auf arm64), FAT32-ESP (256 MB, GRUB per `grub.install()` installiert)
und ext4-Root. Das ist die Datei, die auf die SD-Karte muss — **nicht** die
`.iso`.

Verifiziert per `gdisk -l` (GPT + EF00-ESP + 8300-Root vorhanden) und per
QEMU-Boot-Test als echtes virtio-Block-Device (nicht als CD-ROM wie beim
ersten ISO-Test) — bootet komplett durch bis zum Login-Prompt inkl.
VyOS-Config-Migration ("Configuration success").

## Build

Auf eigener Maschine (nativ arm64 oder amd64 mit `binfmt`/QEMU registriert —
`docker run --rm --privileged multiarch/qemu-user-static --reset -p yes`
falls noch nicht geschehen):

```bash
cd vyos-build
docker build -t vyos/vyos-build docker
docker run --rm -it --privileged -v $(pwd):/vyos -w /vyos vyos/vyos-build:rolling bash
```

Kernel selbst bauen (Container zieht sonst ein vorgebautes Kernel-Paket von
`packages.vyos.net` ohne die Mox-Fixes):

```bash
# im Container:
cd scripts/package-build/linux-kernel
git clone --branch v6.18.50 --depth 1 \
  https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git linux
python3 build.py --packages linux-kernel
# erzeugt linux-image-*.deb / linux-headers-*.deb im selben Verzeichnis
```

Kernel-Build ist mit dem vollen arm64-Defconfig (alle SoCs, nicht nur Mox)
groß — mehrere Stunden unter QEMU-Emulation auf x86-Host, deutlich schneller
(~20 Min) nativ auf einem arm64-Rechner.

Eigenes Kernel-Paket vor dem offiziellen bevorzugen: einfach die `.deb`s
nach `packages/` kopieren — dort hat VyOS bereits einen
fertigen Mechanismus (`config/packages.chroot` + Pin-Priority 1001 in
`data/live-build-config/archives/local-packages.pref.chroot`), kein eigenes
APT-Repo/reprepro nötig:

```bash
cp scripts/package-build/linux-kernel/linux-image-6.18.50-vyos_6.18.50-1_arm64.deb \
   scripts/package-build/linux-kernel/linux-headers-6.18.50-vyos_6.18.50-1_arm64.deb \
   packages/
```

Dann das eigentliche Image bauen — **`generic-raw`, nicht `generic`**
(siehe Abschnitt oben, warum):

```bash
sudo ./build-vyos-image --architecture arm64 --build-by "maltejk@gmail.com" generic-raw
```

Ergebnis: `build/vyos-<version>-generic-raw-arm64.raw` (und zusätzlich das
`.iso`, aber das ist nur ein Zwischenschritt für den Rohimage-Bau, nicht
zum Flashen gedacht). Verifizieren, dass das eigene Kernel-Paket gewonnen
hat — im Build-Log muss `Get: ... file:/root/packages ./ linux-image-...`
stehen, nicht ein Download von `packages.vyos.net`.

## Flash auf Mox (SD-Karte)

Mox' SPI-Flash-U-Boot reicht aus, kein `mox-imager`/Secure-Firmware-Rebuild
nötig für normalen OS-Betrieb (nur für Factory-Reset/Recovery relevant, siehe
[docs.turris.cz/hw/mox/rescue-modes](https://docs.turris.cz/hw/mox/rescue-modes/)).

```bash
sudo dd if=build/vyos-<version>-generic-raw-arm64.raw of=/dev/sdX bs=4M status=progress conv=fsync
```

SD-Karte muss mindestens 10 GB haben (`disk_size`-Default in
`scripts/image-build/defaults.py`) — das `.raw` ist exakt so groß, `dd`
schreibt die komplette Datei unabhängig von der tatsächlich belegten
Root-Partition.

**Möglicher Quirk, falls GRUB nicht durchbootet:** das Debian-Wiki nennt für
den (anderen, extlinux-basierten) Debian-Netboot-Installer einen Namens-Quirk
— Mox' Stock-U-Boot sucht dort das Device-Tree unter `mvebu-turris_mox.dtb`
statt dem Upstream-Namen `marvell/armada-3720-turris-mox.dtb`. Das betrifft
den extlinux-Bootpfad, bei dem der Bootloader die DTB-Datei explizit per
Namen lädt. Unser `.raw`-Image nutzt echtes GRUB-EFI (U-Boots EFI-Personality
reicht ihr eigenes, einkompiliertes Device-Tree über die EFI-Config-Table an
GRUB/Kernel durch, ganz ohne DTB-Datei in der ESP) — der Quirk sollte hier
also gar nicht greifen. Falls GRUB auf echter Hardware trotzdem hängen
bleibt, als Erstes hier ansetzen: ESP mounten und prüfen, ob U-Boot
überhaupt ein Device-Tree findet/lädt (Serial-Konsole beobachten, siehe
unten).

Boot-Reihenfolge auf Mox über DIP-Schalter/Boot-Select (SD vs. eMMC vs. USB)
— siehe [docs.turris.cz/hw/mox/microsd](https://docs.turris.cz/hw/mox/microsd/).
Serial-Konsole zum Debuggen: [docs.turris.cz/hw/mox/serial-boot](https://docs.turris.cz/hw/mox/serial-boot/)
(115200 8N1, jetzt mit `CONFIG_SERIAL_MVEBU_UART=y` auch im VyOS-Kernel aktiv).

## Was getestet ist (QEMU, kein echtes Mox-Board verfügbar)

Gebaut und geprüft auf einem nativen aarch64-Build-Host (kein x86/QEMU-User-Emulation):

- Kernel-`.deb` gebaut, Config aus dem `.deb` extrahiert und verifiziert:
  `CONFIG_MVNETA`, `CONFIG_MOXTET`, `CONFIG_NET_DSA`, `CONFIG_NET_DSA_MV88E6XXX`,
  `CONFIG_SPI_ARMADA_3700`, `CONFIG_SERIAL_MVEBU_UART` alle korrekt gesetzt.
- `generic-raw`-Image gebaut, eigenes Kernel-Paket bestätigt eingebunden
  (nicht der Stock-Kernel von packages.vyos.net).
- `.raw`-Datei mit `gdisk -l` geprüft: echtes GPT, FAT32-ESP (Typ EF00),
  ext4-Root (Typ 8300).
- In QEMU (`qemu-system-aarch64`, `-cpu max`, UEFI-Firmware `AAVMF`/`QEMU_EFI.fd`,
  **ohne KVM**, Softwareemulation) als echtes virtio-Block-Device (nicht
  CD-ROM) gebootet: GRUB-EFI → Kernel → systemd → VyOS-Router-Service →
  Config-Migration → Login-Prompt, alles erfolgreich durchgelaufen
  ("Configuration success").

Das bestätigt: Kernel + GRUB-EFI-Bootkette funktionieren generisch unter
UEFI. Was QEMU **nicht** prüfen kann, weil es keine Armada-3720-Hardware
emuliert: mvneta-NIC, Moxtet-Bus, LAN-Switch-Modul, SPI-Flash, eMMC/SD-Host —
das bleibt dem echten Board vorbehalten.

## Bekannte Risiken / offen

- Debian-Wiki nennt bekannte MMC/USB3-Aussetzer nach dem Boot auf Mox
  (Ursache ungeklärt, betraf dort den extlinux-basierten Installer-Kernel
  nicht) — im Auge behalten, ob das auch mit diesem Kernel auftritt.
- Kein Zugriff auf physisches Mox-Board — Kernel-Config und Image-Format sind
  jetzt beide verifiziert (Kconfig-Symbole passen zu Mox' DTB, `.raw`-Image
  bootet nachweislich als Block-Device via GRUB-EFI), aber die
  Mox-spezifische Hardware selbst (s.o.) ist ungetestet. Bitte nach Flash
  Ethernet, LAN-Modul (falls vorhanden), USB3 und Watchdog verifizieren.
