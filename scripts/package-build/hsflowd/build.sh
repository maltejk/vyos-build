#!/bin/sh
# host-sflow Makefiles hardcode gcc, ar, ranlib, clang and the build
# architecture; point them at the host toolchain when cross compiling.
set -e
ARCH=$(dpkg-architecture -qDEB_HOST_ARCH)
P=
if [ "$ARCH" != "$(dpkg --print-architecture)" ]; then
    T=$(dpkg-architecture -qDEB_HOST_GNU_TYPE)
    P=$T-
    CLANG="clang --target=$T"
    export PKG_CONFIG_LIBDIR=/usr/lib/$(dpkg-architecture -qDEB_HOST_MULTIARCH)/pkgconfig:/usr/share/pkgconfig
fi
sed -i "s/dpkg --print-architecture/echo $ARCH/" Makefile
sed -i -e "s/= *gcc /= ${P}gcc /" -e "s/ar cr /${P}ar cr /" -e "s/ranlib /${P}ranlib /" \
    src/json/Makefile src/sflow/Makefile
make deb CLANG="${CLANG:-clang}" FEATURES='PCAP DROPMON DBUS PSAMPLE VPP'
