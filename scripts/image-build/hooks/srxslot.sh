#!/bin/sh
# Copyright VyOS maintainers and contributors <maintainers@vyos.io>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 2 or later as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
# File: scripts/image-build/hooks/srxslot.sh
# Purpose: pack the live squashfs and the kernel image into an SRX slot
#          tarball (srxslot-<version>.tar) for the SRXBOOT slot installer.
#
# The tarball contains:
#   MANIFEST           version, sha256 sums and the package list
#   <version>.squashfs the root filesystem, named after the image version
#   vmlinux            the kernel image
#
# The SRXBOOT shim (U-Boot -> shim -> kernel) is derived from the kernel
# image in a later step, not here.
#
# Usage: srxslot.sh <version> <architecture>

set -e

version="$1"
arch="$2"
[ -n "$version" ] && [ -n "$arch" ] || { echo "E: usage: srxslot.sh <version> <architecture>" >&2; exit 1; }

build_dir="$(pwd)"

squashfs="$build_dir/binary/live/filesystem.squashfs"
[ -f "$squashfs" ] || { echo "E: $squashfs not found - live-build produced no squashfs" >&2; exit 1; }

# Kernel images land in binary/live/ as vmlinux-<ver>-<flavour> (mips64el ELF)
# or vmlinuz-... on other architectures.
kernel=$(ls "$build_dir"/binary/live/vmlinux-* "$build_dir"/binary/live/vmlinuz-* 2>/dev/null | head -n 1)
[ -n "$kernel" ] || { echo "E: no kernel image found in binary/live/" >&2; exit 1; }

out="srxslot-${version}.tar"
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT

cp "$squashfs" "$staging/${version}.squashfs"
cp "$kernel" "$staging/vmlinux"

{
    echo "version=$version"
    echo "arch=$arch"
    echo "squashfs=${version}.squashfs"
    echo "kernel=$(basename "$kernel")"
    echo "created=$(date -u +%FT%TZ)"
    echo
    (cd "$staging" && sha256sum "${version}.squashfs" vmlinux)
    if [ -f "$build_dir/binary/live/packages.txt" ]; then
        echo
        echo "packages:"
        cat "$build_dir/binary/live/packages.txt"
    fi
} > "$staging/MANIFEST"

tar -C "$staging" -cf "$out" MANIFEST "${version}.squashfs" vmlinux
echo "$out"
