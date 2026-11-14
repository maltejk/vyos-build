#!/bin/sh

SRC="isc-kea"
BRANCH="Kea-3.0.3"

# Fetch debian packaging repo
git clone --branch ${BRANCH} https://gitlab.isc.org/isc-projects/kea-packaging.git
rm -rf isc-kea/debian
cp -r kea-packaging/debian isc-kea/
rm -rf kea-packaging

cd $SRC

# Determine version from git tag
TAG=$(git describe --tags --exact-match)
VERSION="${TAG#Kea-}"

# Modify debian files, add version, remove docs/manpages and unnecessary packages
sed -i "s/{VERSION}/$VERSION/g" debian/changelog
sed -i 's/{ISC_VERSION}/vyos/g' debian/changelog
sed -i 's/{ISC_VERSION}/vyos/g' debian/rules
sed -i '/meson compile -C build doc/d' debian/rules
sed -Ei '/^Package: isc-kea-(premium|subscriber)/,/^$/d' debian/control
sed -i '/usr\/share\/man/d' debian/*.install
sed -i '/usr\/share\/doc\/kea/d' debian/*.install
echo "usr/share/doc/kea/*" >> debian/not-installed
echo "usr/share/kea/meson-info/*" >> debian/not-installed
rm -rf debian/isc-kea-doc.install debian/isc-kea-subscriber* debian/isc-kea-premium*

# Cross build (DEB_HOST_ARCH differs from the build arch): rules runs a plain
# `meson setup build`; add the image's cross file and the multiarch libdir
# (the native default applies to native builds only).
if [ "$(dpkg-architecture -qDEB_HOST_ARCH)" != "$(dpkg --print-architecture)" ]; then
    sed -i "s#meson setup build#& --cross-file $(dpkg-architecture -qDEB_HOST_ARCH) --libdir lib/$(dpkg-architecture -qDEB_HOST_MULTIARCH)#" debian/rules
fi
