# VyOS rolling auf Turris Mox

**Status: vollständig funktionsfähig auf echter Hardware** — sauberer Boot,
`Configuration success`, Ethernet + 8-Port-LAN-Switch-Modul + SSH bestätigt
(siehe Abschnitt "Auf echter Hardware verifiziert" unten).

Turris Mox (Marvell Armada 3720, dual Cortex-A53) ist kein offiziell
unterstütztes VyOS-Board. VyOS baut aber ein generisches arm64-Image
(`generic` flavor), das auf jeder Plattform läuft, deren Treiber im Kernel
aktiv sind. Armada-3720-Support war im VyOS-Kernel-Defconfig nur teilweise
aktiv — gefixt in `scripts/package-build/linux-kernel/config/arm64/vyos_defconfig`.
Zusätzlich brauchte es einen alternativen Bootpfad (extlinux statt GRUB-EFI),
weil Mox' Werks-U-Boot zu alt für den arm64-Kernel-EFI-Stub ist — Details
weiter unten.

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

**Wichtig: `build-vyos-image` allein reicht nicht.** Das oben beschriebene
`extlinux.conf` + entpackte `vmlinuz` + SPI-NOR-DTB + `hw-id` sind KEIN
Teil des normalen Build-Prozesses — die ESP/Root-Partition des `.raw` muss
danach manuell (oder per Skript) gepatcht werden, bevor es aufs Board passt:

```bash
# .raw loop-mounten
sudo losetup -fP --show build/vyos-<version>-generic-raw-arm64.raw   # -> /dev/loopN
sudo mount /dev/loopNp2 /mnt/esp    # FAT32-ESP
sudo mount /dev/loopNp3 /mnt/root   # ext4-Root

# vmlinuz entpacken + Dateien auf die ESP kopieren
gunzip -c /mnt/root/boot/<version>/vmlinuz > /tmp/vmlinuz.raw
sudo mkdir -p /mnt/esp/extlinux
sudo cp /tmp/vmlinuz.raw /mnt/esp/extlinux/vmlinuz
sudo cp /mnt/root/boot/<version>/initrd.img /mnt/esp/extlinux/initrd.img
sudo cp spi-nor-mox.dtb /mnt/esp/extlinux/spi-nor-mox.dtb   # s.o., einmalig per Serial-Konsole extrahiert
# extlinux.conf schreiben (Inhalt s.o.)

# config.boot patchen: eth0 hw-id + console device ttyMV0 (Inhalt s.o.)
sudo sed -i 's/device ttyAMA0 {/device ttyMV0 {/' /mnt/root/boot/<version>/rw/opt/vyatta/etc/config/config.boot

sudo umount /mnt/esp /mnt/root
sudo losetup -d /dev/loopN
```

Das SPI-NOR-DTB ist Board-Revisions-abhängig (enthält u.a. die
Modul-Topologie) — einmal pro Board-Exemplar per Serial-Konsole extrahieren
(siehe oben), dann für alle folgenden Image-Builds desselben Boards
wiederverwenden.

**GRUB-EFI bootet auf echter Hardware NICHT — bestätigt per Serial-Konsole.**
Mox' Werks-U-Boot ist uralt (`U-Boot 2018.11`, `jenkins-turris-os-packages-kittens-mox-90`,
aus dem SPI-Flash). Dessen EFI_LOADER hat einen bekannten Bug beim Chainloaden
von GRUB→Kernel: der arm64-Kernel-EFI-Stub bricht mit
```
EFI stub: ERROR: FIRMWARE BUG: efi_loaded_image_t::image_base has bogus value
EFI stub: ERROR: FIRMWARE BUG: kernel image not aligned on 64k boundary
EFI stub: ERROR: Unable to construct new device tree.
Failed to boot both default and fallback entries.
```
ab — U-Boot meldet dem Kernel eine falsche Bildadresse, der Kernel verweigert
aus Sicherheitsgründen den Start. Einmal führte das sogar zu einem echten
CPU-Exception-Crash (`"Synchronous Abort" handler`) statt eines sauberen
Fehlers. Das ist **kein Bug in unserem Image** — reines Firmware-Alter.

**Funktionierender Bootpfad: extlinux (direktes `booti`, kein EFI).**
Mox' `distro_bootcmd` prüft laut `printenv` in `scan_dev_for_boot` erst
`extlinux/extlinux.conf`, dann EFI erst als Fallback — genau das nutzen wir,
um den kaputten EFI-Pfad komplett zu umgehen (matches Debians eigene
funktionierende Methode für dieses Board). Drei zusätzliche Fixes waren
nötig, jeweils per Serial-Konsole live am Gerät gefunden:

1. **`vmlinuz` muss unkomprimiert sein.** VyOS' `.deb`-Paket liefert ein
   gzip-komprimiertes `vmlinuz` (`booti` erkennt das nicht — `Bad Linux
   ARM64 Image magic!`). Fix: `gunzip -c vmlinuz > vmlinuz.raw`, das
   entpackte File verwenden (echtes `arch/arm64/boot/Image`).
2. **DTB muss aus dem SPI-NOR-Flash kommen, nicht vom Kernel-Paket.**
   Mox' altes U-Boot patcht beim Booten board-spezifische Werte
   (Modul-Topologie, ECDSA-Key, Board-Version) in ein mitgeliefertes
   Device-Tree hinein (`ft_board_setup()`, läuft bei **jedem** Boot über
   `bootm`/`booti`, nicht nur bei EFI). Das moderne Mainline-DTB aus dem
   6.18.50-Kernel hat andere Node-Pfade als dieses alte U-Boot erwartet →
   `ERROR: board-specific fdt fixup failed: FDT_ERR_NOTFOUND` → Hard-Hang
   ("must RESET the board to recover"). U-Boots eigener Bootscript lädt
   beim normalen Boot selbst ein kompatibles DTB aus SPI-NOR
   (`sf read $fdt_addr_r 0x7f0000 0x10000`, sichtbar in `mox_distro_bootcmd`)
   — genau das brauchen wir auch für unseren extlinux-Eintrag.

   Extraktion (kein serielles Custom-Tool nötig, nur Standard-U-Boot-Befehle;
   `tftpput` scheitert an vielen TFTP-Servern wie dnsmasq, die nur Lesen
   können — deshalb per Hex-Dump über die Konsole):
   ```
   => sf probe; sf read 0x4f00000 0x7f0000 0x10000
   => fdt addr 0x4f00000
   => fdt header          # totalsize ablesen, hier 0x4b5c (19292 Bytes)
   => md.b 0x4f00000 0x4b5c
   ```
   Den `md.b`-Hex-Dump aus dem Serial-Log parsen (Format
   `<addr>: <16 Hex-Bytes>  <ASCII>`) und als Binärdatei rekonstruieren —
   ergibt ein valides, mit `dtc` dekompilierbares DTB, das schon die
   richtigen Switch-Chip-Nodes für das verbaute Modul enthält (z.B.
   `switch0@2`/`switch1@2`/`switch2@2` für ein 8-Port-Peridot-Modul).
3. **`eth0` braucht eine explizite `hw-id`** in `config.boot`, sonst hängt
   die VyOS-Config-Aktivierung beim Boot fest ("interface 'eth0' still has
   no hw-id configured ... failed!", danach kein Fortschritt mehr, auch
   nicht auf Enter am Serial). Die echte MAC steht in U-Boots `printenv`
   als `ethaddr`:
   ```
   interfaces {
       ethernet eth0 {
           hw-id "d8:58:d7:00:ce:ee"
           address dhcp
       }
   }
   ```

4. **`system console device ttyMV0` in `config.boot` lässt den kompletten
   Config-Commit fehlschlagen** ("Configuration error"). VyOS-1x' Schema für
   `system console device <name>` akzeptiert nur eine feste Liste bekannter
   Namensmuster (`ttyS*`, `ttyUSB*`, `ttyAMA*`, `hvc*`, …) — `ttyMV0`
   (Marvell-UART) ist dort nicht vorgesehen → `[ system console device
   ttyMV0 ] Invalid value` → `[[system console]] failed`. Die
   Priority-Queue verarbeitet trotzdem alle anderen Knoten (deshalb
   funktionierten Netzwerk/SSH schon vorher trotz der Fehlermeldung), aber
   der Gesamtstatus wird als Fehler markiert. **Fix: den `console`-Block
   aus `config.boot` komplett weglassen** — die serielle Konsole
   funktioniert trotzdem, weil `Serial Getty on ttyMV0` unabhängig davon
   direkt aus dem Kernel-`console=`-Bootparameter kommt, nicht aus VyOS'
   eigenem Config-Schema. (Root Cause gefunden per `vyos-config-debug`
   Kernel-Bootparameter, der `/tmp/boot-config-trace` mit dem echten
   Python-Traceback erzeugt — ohne dieses Flag zeigt `vyos-boot-config-loader.py`
   nur die nichtssagende "Configuration error"-Zeile.)

**Finales, funktionierendes `extlinux.conf`** (liegt auf der ESP-Partition,
`/extlinux/extlinux.conf`, referenziert Dateien relativ zur selben Partition):
```
DEFAULT VyOS
LABEL VyOS
    KERNEL /extlinux/vmlinuz
    FDT /extlinux/spi-nor-mox.dtb
    INITRD /extlinux/initrd.img
    APPEND boot=live rootdelay=5 noautologin net.ifnames=0 biosdevname=0 vyos-union=/boot/<version> console=ttyMV0,115200 earlycon=ar3700_uart,0xd0012000
```
(`vmlinuz` = entpackt, siehe Punkt 1; `spi-nor-mox.dtb` = aus SPI-NOR
extrahiert, siehe Punkt 2; `console=ttyMV0` statt `ttyAMA0`, siehe unten
— das ist der Kernel-Bootparameter, unabhängig vom `config.boot`-Schema-Problem
aus Punkt 4.)

**Serial-Konsole ist `ttyMV0`, nicht `ttyAMA0`.** `data/architectures/arm64.toml`
setzt `console_type = "ttyAMA"` als generischen arm64-Default (passt z.B. für
QEMU/Raspberry Pi mit PL011-UART) — Armada 3720 hat aber einen eigenen
Marvell-UART-Treiber (`CONFIG_SERIAL_MVEBU_UART`, Device-Node `ttyMV0`).
Bestätigt aus U-Boots eigenem `rescue_args=console=ttyMV0,115200
earlycon=ar3700_uart,0xd0012000`. Das gehört nur ins `APPEND` der
`extlinux.conf` (Kernel-Bootparameter) — **nicht** in `config.boot`'s
`system console`-Block, siehe Punkt 4.

Boot-Reihenfolge: kein physischer DIP-Schalter nötig — Mox (SD-only-Variante,
ohne eMMC) bootet laut Turris-Doku ohnehin primär von der microSD-Karte.
Serial-Konsole zum Debuggen: [docs.turris.cz/hw/mox/serial-boot](https://docs.turris.cz/hw/mox/serial-boot/)
(115200 8N1).

## Auf echter Hardware verifiziert (nicht nur QEMU)

Vollständig getestet auf einem echten Turris Mox (Board-Version 22, SD-only,
8-Port-Peridot-Switch-Modul verbaut) über eine USB-Serial-Konsole:

- U-Boot bootet SPI-Flash → findet SD-Karte → lädt `extlinux/extlinux.conf`
  → `booti` mit entpacktem `vmlinuz` + SPI-NOR-DTB → Kernel bootet vollständig
  durch bis zum systemd-Multi-User-Target und VyOS-Router-Service.
- `dmesg` bestätigt alle gepatchten Treiber laufen real:
  `mvneta d0030000.ethernet e2: renamed from eth0` und
  `mvneta d0040000.ethernet e3: renamed from eth1` (beide Onboard-NICs),
  `moxtet spi0.1` geladen, `mv88e6085 d0032004.mdio-mii:10: switch 0x1900
  detected: Marvell 88E6190` (LAN-Switch-Modul erkannt).
- Per SSH auf die laufende Instanz verbunden (`vyos`/Standard-Passwort):
  `show version` bestätigt `VyOS 1.5-rolling-... generic-raw ... built by
  maltejk@gmail.com`; `ip -br a` zeigt `eth0` mit per DHCP bezogener IP
  sowie **alle 8 Switch-Ports als eigene Interfaces**
  (`eth1@eth9` … `eth8@eth9`) — Moxtet + DSA/mv88e6xxx-Kette komplett
  funktionsfähig.
- **`vyos-router: Configuration success`** — nach Fix Nr. 4 (Punkt oben)
  läuft der komplette Boot inklusive Config-Commit fehlerfrei durch, keine
  offenen Fehlermeldungen mehr.

## Bekannte Risiken / offen

- USB3, SATA-Modul, SFP-Modul, Watchdog-Device (`/dev/watchdog*`) und
  Mini-PCIe sind noch nicht einzeln durchgetestet — Treiber sind aktiv,
  aber ungetestet mangels angeschlossener Peripherie beim Test.
- Debian-Wiki nennt bekannte MMC/USB3-Aussetzer nach dem Boot auf Mox bei
  ihrem (anderen) Installer-Kernel — bisher bei unserem Test nicht
  aufgetreten, aber Langzeitbetrieb noch nicht beobachtet.
- Systemzeit ist beim ersten Boot falsch (keine RTC, kein NTP-Sync direkt
  am Anfang) — führt zu harmlosen, aber zahlreichen PAM-Warnungen
  ("account root has password changed in future") im Log. NTP ist
  konfiguriert und sollte das nach kurzer Zeit selbst korrigieren.
- Kein `vyos-1x`-Upstream-Bugreport für das `ttyMV0`-Schema-Problem (Punkt 4
  oben) erstellt — wäre der sauberere Fix, falls jemand Board-übergreifend
  an VyOS/Mox-Support arbeiten will.
