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

Fix: neue Build-Flavor `data/build-flavors/generic-sbc.toml`
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

Dann das eigentliche Image bauen — **`generic-sbc`, nicht `generic`**
(siehe Abschnitt oben, warum):

```bash
sudo ./build-vyos-image --architecture arm64 --build-by "maltejk@gmail.com" generic-sbc
```

Ergebnis (Flavor `generic-sbc`, Zusatz-Artefakte `.cdx.json`/`.spdx.json` ignoriert):

- `build/vyos-<version>-generic-sbc-arm64.raw` — Plattenimage (GPT, ESP + Root),
  mit `dd` auf die SD-Karte schreiben (siehe unten). Nur für die Erstinstallation.
- `build/vyos-<version>-generic-sbc-arm64.iso` — echtes ISO9660-Installationsimage,
  für Updates auf dem laufenden Mox per `add system image <url>` (siehe
  "Image-Updates auf dem Mox").

Verifizieren, dass das eigene Kernel-Paket gewonnen
hat — im Build-Log muss `Get: ... file:/root/packages ./ linux-image-...`
stehen, nicht ein Download von `packages.vyos.net`.

## Flash auf Mox (SD-Karte)

Mox' SPI-Flash-U-Boot reicht aus, kein `mox-imager`/Secure-Firmware-Rebuild
nötig für normalen OS-Betrieb (nur für Factory-Reset/Recovery relevant, siehe
[docs.turris.cz/hw/mox/rescue-modes](https://docs.turris.cz/hw/mox/rescue-modes/)).

```bash
sudo dd if=build/vyos-<version>-generic-sbc-arm64.raw of=/dev/sdX bs=4M status=progress conv=fsync
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
sudo losetup -fP --show build/vyos-<version>-generic-sbc-arm64.raw   # -> /dev/loopN
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

## Peripherie-Checks (auf diesem konkreten Board)

- **Watchdog**: `/dev/watchdog0` vorhanden, Identity "Armada 37xx Watchdog",
  120s Timeout, Status korrekt "inactive" (per `wdctl` nur ausgelesen, nicht
  scharf geschaltet, um keinen ungewollten Reset auszulösen).
- **USB3**: `xhci-hcd d0058000.usb: Host supports USB 3.0 SuperSpeed`,
  Controller sauber initialisiert, zwei xHCI-Busse (USB2+USB3) registriert.
  Kein Gerät zum Durchsatztest angeschlossen gewesen.
- **SFP / SATA-Modul / Mini-PCIe**: auf diesem Board **nicht verbaut** — U-Boots
  `printenv` listet nur `1: Peridot Switch Module (8-port)` in der
  Modul-Topologie, `dmesg` zeigt keine sfp/ahci-Probe-Versuche, `lspci`/
  `/sys/bus/pci/devices/` sind leer (Aardvark-PCIe-Node bleibt inaktiv ohne
  erkanntes Modul, analog zum SFP-Verhalten im DTS). Treiber sind aktiv,
  aber an diesem Exemplar nichts zum Testen vorhanden.

## Switch-Port-Nummerierung (8-Port-Peridot-Modul)

Produktiv-Config (Stand 2026-10-01): jeder der 8 Switch-Ports läuft als
eigenständiges, isoliertes Layer-2/3-Interface mit eigenem `/24` —
**keine** Bridge zwischen den Ports. Per `arping`+`tcpdump`-Test
nachweislich kein Cross-Talk zwischen beliebigen Portpaaren, auch nicht
über ein physisches Loop-Kabel (siehe technische Findings #13/#14).

**Die `eth1`..`eth8`-Zuordnung ist jetzt garantiert stabil über Reboots
hinweg** — zuvor hing sie von der Kernel/DSA-Registrierungsreihenfolge ab
und konnte zwischen Boots wechseln (an einem Boot `eth1`..`eth8` mit
Conduit `eth9`, an einem anderen `lan1`..`lan8` mit Conduit `eth1`, siehe
Findings #10). Fix: eine udev-Regel
(`/etc/udev/rules.d/71-mox-net-naming.rules`, liegt im persistenten
`rw`-Overlay, überlebt Reboots) pinnt jeden Port über seinen
**hardware-stabilen** `phys_port_name` (`p1`..`p8`, kommt direkt vom
Switch-Chip-Register, unabhängig von Registrierungs-Timing) auf einen
festen `ethN`-Namen, plus die beiden Onboard-mvneta-Ports über ihren
eigenen Platform-Device-Pfad auf `eth0`/`eth9`. Verifiziert über zwei
unabhängige Reboots: identisches Mapping beide Male (siehe technische
Findings #15/#16).

Logische Zuordnung (Interface-Name → Subnetz), jetzt dauerhaft:

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
    (alle: 192.168.10<N>.1/24, Gateway-Adresse = eigener Port;
     "pN" = phys_port_name, der echte, von udev gepinnte Hardware-Index)

    CPU/Conduit-Port (DSA-intern, nicht extern nutzbar): eth9
    Onboard-WAN-Port (separat vom Switch-Modul):         eth0
```

**Eine Sache bleibt offen**: ob `phys_port_name` `p1`..`p8` auch mit der
echten **Silkscreen-Beschriftung** 1..8 auf dem Peridot-Modul
übereinstimmt (links-nach-rechts oder eine andere Reihenfolge), wurde noch
nicht gegen die echte Hardware getestet — die 2×4-Anordnung oben ist rein
schematisch für die Doku, keine Fotografie des echten Moduls. Das
*Mapping selbst* (`ethN` ↔ `pN`) ist aber jetzt garantiert fest, nur die
Zuordnung `pN` ↔ aufgedrucktem Port-Label ist noch unverifiziert. Falls das
für den Einsatz wichtig wird: ein Kabel in den mit "1" beschrifteten Port
stecken und prüfen, welches `ethN`/`pN` Carrier bekommt
(`ip -br link`).

## Firmware-Update-Versuch (U-Boot 2018.11 → 2022.07)

Nutzer hat eigenständig Mox' komplette Firmware aktualisiert (TF-A BL1/BL2/BL31
v2.7, Secure Firmware 2022.06.11, **U-Boot 2022.07**, statt der originalen
2018.11-Werksversion). Ergebnis beim erneuten Test des GRUB-EFI-Pfads
(`extlinux.conf` temporär deaktiviert, um den EFI-Fallback zu erzwingen):

- Der ursprüngliche Crash (`FIRMWARE BUG: efi_loaded_image_t::image_base has
  bogus value`, teils mit CPU-Exception) **tritt nicht mehr auf** — GRUB lädt
  und zeigt sein Boot-Menü sauber an.
- Der Kernel-Start danach hängt aber weiterhin **lautlos** (kein Login, keine
  DHCP-Anfrage im Netzwerk beobachtet) — vermutlich weil GRUBs generierte
  Kernel-Zeile `console=ttyAMA0` verwendet (VyOS' genereller arm64-Default,
  siehe oben), nicht `ttyMV0`, wodurch selbst ein erfolgreich bootender Kernel
  keine sichtbare Ausgabe hätte. Nicht abschließend verifiziert, ob der Kernel
  dahinter tatsächlich läuft.
- **Fazit: extlinux bleibt der verifiziert funktionierende Weg.** Das
  Firmware-Update verbessert den EFI-Pfad sichtbar, macht ihn aber (noch)
  nicht zuverlässig nutzbar — würde zusätzlich einen GRUB-Konsolen-Fix
  brauchen (analog zum `ttyMV0`-Fix in `config.boot`, nur für GRUBs eigene
  Boot-Menü-Konfiguration statt `config.boot`).

Mit `extlinux` + `booti` (unser eigentlicher Weg) bringt das Update dagegen
zwei echte Verbesserungen:

- **Modernes Mainline-DTB funktioniert jetzt direkt** — kein
  `FDT_ERR_NOTFOUND` mehr, das Board-Fixup des neuen U-Boot akzeptiert die
  Node-Struktur des 6.18.50-Kernel-DTB. Die SPI-NOR-DTB-Extraktion (Punkt 2
  oben) ist mit aktualisierter Firmware **nicht mehr nötig** — bleibt aber
  Pflicht für alle, die auf der originalen 2018.11-Werksfirmware bleiben.
- **DHCP/Netzwerk-Stack ist deutlich robuster** — PXE-Boot-Versuche mit dem
  alten U-Boot brauchten dutzende BOOTP-Retries und scheiterten meist ganz
  (0 von 40 automatisierten Versuchen erfolgreich); mit 2022.07 bindet DHCP
  zuverlässig innerhalb von ~250ms.

## PXE/Netzwerk-Boot — funktioniert nur teilweise, zwei getrennte Probleme gefunden

Test: SD-Karte entfernt, dnsmasq (DHCP+TFTP) auf dem direkt verbundenen
Build-Host, `boot_targets=mmc0 usb0 pxe dhcp` fällt ohne SD-Karte automatisch
auf `pxe` durch.

1. **Watchdog-Reboot-Loop.** Das neue U-Boot startet beim Booten automatisch
   einen Hardware-Watchdog mit 60s Timeout (`WDT: Started watchdog@8300 with
   servicing (60s timeout)`, noch vor dem Laden der Umgebung aus SPI-Flash —
   also fest im Board-Init-Code, nicht per Env-Variable abschaltbar). Über
   den langsamen Test-USB-Ethernet-Dongle (~2 MiB/s) dauert allein der
   Transfer von initrd (31 MB) + vmlinuz (34 MB) + Kernel-Boot spürbar länger
   als 60s, ohne dass in der Zeit irgendetwas den Watchdog bedient — Reset
   mitten im Boot, endlos wiederholt. **Live am Gerät verifiziert:**
   `wdt dev watchdog@8300` gefolgt von `wdt stop` an der U-Boot-Konsole (vor
   dem eigentlichen Boot-Befehl) verhindert den Reset zuverlässig — das Board
   bleibt danach stabil stehen, auch wenn der nachfolgende Boot selbst
   fehlschlägt (siehe Punkt 2). Nicht dauerhaft in die Firmware übernommen
   (`saveenv` verändert das gespeicherte U-Boot-Environment im SPI-NOR
   permanent) — wer das reproduzierbar braucht, müsste `wdt stop` vorn in
   die `bootcmd`/`mox_boot`-Kette einbauen und speichern. Auf echtem
   Gigabit-LAN dürfte der Transfer schnell genug sein, dass dieses Problem
   gar nicht erst auftritt.
2. **Kein Root-Dateisystem über PXE bereitgestellt.** Selbst wenn Punkt 1
   behoben ist, scheitert der Boot mit
   ```
   BOOT FAILED! Unable to find a medium containing a live file system
   ```
   — live-boot droppt in eine BusyBox-Rescue-Shell. Grund: unsere
   `extlinux.conf`/`pxelinux.cfg` lädt nur `vmlinuz`+`initrd`+DTB per TFTP,
   nicht die eigentliche Root-Dateisystem-Squashfs (~450 MB,
   `<version>.squashfs`), die beim SD-Karten-Boot lokal auf der Karte liegt.
   Für echtes Netzwerk-Booten fehlt noch live-boots `fetch=`-Mechanismus
   (Squashfs per HTTP/TFTP-URL nachladen) oder ein NFS-Root-Setup — beides
   nicht umgesetzt, da PXE/LAN-Boot nicht der primäre Zielweg ist.

**Fazit:** PXE/LAN-Boot ist mit aktualisierter Firmware technisch näher an
funktionsfähig (Netzwerk-Stack + DTB-Kompatibilität beide gelöst), aber ohne
zusätzliche live-boot-Netboot-Konfiguration (Squashfs-Fetch) nicht
einsatzbereit. SD-Karte bleibt der vollständig verifizierte, empfohlene Weg.

## `reboot` hing — Ursache und Fix (Kernel-Patch + U-Boot-Variable)

Symptom (2026-10-01): `reboot` aus VyOS fährt sauber runter, letzte Konsolen-
zeile `reboot: Restarting system`, danach Stille, rote LED aus, nur
Power-Cycle hilft. U-Boots eigenes `reset` funktioniert immer.

**Ursache (per Messung mit zeitgestempeltem Serial-Log belegt):**

1. Linux ruft beim Reboot den PSCI-`SYSTEM_RESET` auf. Das TF-A
   (`a3700_system_reset()`) versucht zuerst `cm3_system_reset()` (Mailbox an
   den Cortex-M3/WTMI) und schreibt danach unbedingt `MVEBU_WARM_RESET_REG`
   — laut Quellcode-Kommentar "may hang the board" (Hardware-Bug des
   Armada 3720). Dieser Pfad hängt hier zuverlässig, auch mit neuerer
   Firmware (v2024.04.15) und größerem Retry-Budget — der Retry-Ansatz war
   eine Sackgasse.
2. Der Reboot-Notifier des Treibers `armada_37xx_wdt`
   (`watchdog_stop_on_reboot`) stoppt vorher den Hardware-Watchdog wirklich.
   Damit gibt es keinen Rettungsweg mehr.
3. Ein **Watchdog-Ablauf** dagegen setzt den SoC sicher zurück: die WTMI-
   Firmware wandelt ihn in einen sauberen Reset um (`mox_wdt_workaround()`),
   aber **nur wenn die U-Boot-Umgebungsvariable
   `a3720_reset_issue_workaround=yes` im SPI-NOR-Env gesetzt ist**
   (WTMI liest sie nur beim Kaltstart).

Belegt: `sysrq-b` (Watchdog bleibt scharf) erholt sich nach der Restlaufzeit
des Watchdogs; Watchdog auf 4 s + `sysrq-b` bootet nach 4 s sauber (3/3).

**Fix, zwei Teile (beide nötig):**

1. U-Boot-Variable einmalig setzen (Serial-Konsole, im U-Boot-Prompt):

   ```
   setenv a3720_reset_issue_workaround yes
   saveenv
   ```

   Danach einmal Power-Cycle (WTMI liest die Variable nur beim Kaltstart).
   Prüfen: `printenv a3720_reset_issue_workaround`.

2. Kernel-Patch
   `scripts/package-build/linux-kernel/patches/kernel/0006-armada-37xx-wdt-restart-handler.patch`:
   der Watchdog-Treiber bekommt einen Restart-Handler mit Priorität 200
   (vor PSCI, Priorität 129). Er startet den Watchdog mit 1 s Timeout neu
   und wartet bis zu 5 s auf den Reset. Hilft das nicht, greift der
   PSCI-Handler wie bisher als Fallback.

**Test:** mit dem gepatchten Modul (`armada_37xx_wdt.ko`, temporär
geladen) kam nach `reboot` der Firmware-Banner nach ca. 1,5 s und VyOS
war nach ca. 3 min wieder oben (1 Messung; ohne Patch hängt `reboot` ≥15 min).
Das Modul muss genau zum laufenden Kernel passen (gleicher Compiler,
gleiche Config, BTF) — deshalb im `vyos/vyos-build`-Container bauen.

**Ohne den Kernel-Patch** (altes Image): Neustart nur per Power-Cycle, oder
`sysrq-b` nach Setzen des Watchdog-Timeouts auf wenige Sekunden.

## Neue vyos-1x-Namenslogik (ab Kernel 6.18.54-Image): `hw-id` nur einmal für die Switch-Ports

Neuere vyos-1x-Versionen lösen Interface-Namen beim Booten über
`vyos-net-name-resolve.py` auf (Schlüssel: `hw-id`/MAC). Alle 8 Switch-Ports
(DSA) und `eth9` teilen sich dieselbe MAC `d8:58:d7:00:ce:ef`, auch
`ethtool -P` meldet sie überall. Stehen mehrere `hw-id`s mit dieser MAC in
`config.boot` ("multiple entries"), benennt das Skript willkürlich einen Port
um (`eth2` wird zu `vyeth5`, der Rename auf `eth1` scheitert), `eth2` fehlt
dann und der Commit endet mit `Configuration error`
(`Interface "eth2" does not exist!`, `/tmp/boot-config-trace`).

Funktionierende Konfiguration (verifiziert, `Configuration success`, keine
Umbenennung): `hw-id` nur für `eth0` (`...:ee`) und **genau einmal** für die
gemeinsame MAC, und zwar am Port, den das Skript ohnehin als Quelle wählt
(hier `eth2`, deterministisch durch die sysfs-Reihenfolge der festen Namen).
Bei `eth1` und `eth3`..`eth9` den `hw-id`-Eintrag weglassen; die Namen
sichert weiter die udev-Regel `71-mox-net-naming.rules` (`phys_port_name`).
Es erscheinen nur Warnungen ("still has no hw-id configured") ohne Folgen.

## Image-Updates auf dem Mox (`add system image` + `mox-sync-boot`)

Getestet 2026-10-02: `add system image <url>` funktioniert auf dem Mox, wenn
zwei Dinge stimmen:

1. **`BOOT_IMAGE=/boot/<image>/vmlinuz` auf der Kernel-Kommandozeile.** GRUB
   setzt das, U-Boots `extlinux` nicht. Ohne diesen Parameter hält VyOS das
   System für Live-Boot und bricht mit `The system is in live-boot mode.
   Please use "install image" instead.` ab.
2. **`extlinux.conf` auf der ESP kennt das neue Image.** Der Installer kennt nur
   GRUB; er legt `/boot/<image>/` an und kopiert die Konfiguration, aktualisiert
   aber nicht die ESP.

Beides erledigt das mitgelieferte Skript `/usr/local/sbin/mox-sync-boot`
(Flavor `generic-sbc`, nicht ausführbar, daher mit `bash` aufrufen):

```bash
sudo bash /usr/local/sbin/mox-sync-boot -n   # Trockenlauf
sudo bash /usr/local/sbin/mox-sync-boot      # anwenden
```

Es mountet die ESP, schreibt für das Standard-Image (aus GRUBs
`vyos-versions`) und die neuesten weiteren (`MOX_MAX_ENTRIES`, Standard 2,
die ESP hat nur 256 MB) `vmlinuz-<image>` (entpackt) und `initrd-<image>.img`,
erzeugt `extlinux.conf` mit `BOOT_IMAGE=` und `vyos-union=` und löscht
Dateien, die kein Eintrag mehr braucht. Es arbeitet Image für Image, jeder
Zwischenstand ist bootbar. Es warnt, wenn einem Image die `config.boot` fehlt
(`add system image` kopiert die Konfiguration nur bei Antwort `Y` auf "copy it to
the new image?"; getestet: `config.boot`, SSH-Keys und `scripts/` werden übernommen). Ablauf für ein Update:

```
add system image http://<host>/<image>.iso     # Signatur-Rückfrage: y (Selbstbau)
sudo bash /usr/local/sbin/mox-sync-boot
reboot
```

Bei einem Altsystem ohne `BOOT_IMAGE=` einmalig `BOOT_IMAGE=/boot/<image>/vmlinuz`
in die `extlinux.conf` eintragen (oder das Skript dort laufen lassen) — vor dem
ersten `add system image`.

## Bekannte Risiken / offen

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
