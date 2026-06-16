#!/bin/bash -e

# AV-133308: lock the image to the GA LTS kernel series (6.8). The rolling
# cloud kernel (6.17) has a TCP receive-buffer regression (AV-133015 /
# MB-70640); the GA series predates it and receives security updates for the
# LTS lifetime. The rolling metas are removed and blocked so nothing (including
# unattended-upgrade) can cross-grade the kernel to a new series. The old
# kernel's own packages are purged at "finalize" time since the build VM is
# still running that kernel and may need its modules during provisioning.
#
# Usage: lock-kernel.sh <install|finalize> <cloud-provider>
#   install  - install the 6.8 meta, drop the rolling metas and pin them out.
#              Run this BEFORE unattended-upgrade so nothing pulls a new series.
#   finalize - purge the old rolling kernel and assert only 6.8 remains.
#              Run this at the very end of provisioning.

MODE="${1:?usage: lock-kernel.sh <install|finalize> <cloud-provider>}"
CLOUD_PROVIDER="${2:?usage: lock-kernel.sh <install|finalize> <cloud-provider>}"

export DEBIAN_FRONTEND=noninteractive
OLD_KERNEL_SERIES="$(uname -r | cut -d. -f1-2)"

case "${MODE}" in
install)
    apt update
    apt install -y "linux-${CLOUD_PROVIDER}-lts-24.04"
    if [[ ${OLD_KERNEL_SERIES} != "6.8" ]]; then
        apt remove -y "linux-${CLOUD_PROVIDER}" "linux-image-${CLOUD_PROVIDER}" "linux-headers-${CLOUD_PROVIDER}"
    fi
    cat > /etc/apt/preferences.d/99-couchbase-kernel-pin <<EOF
Package: linux-${CLOUD_PROVIDER} linux-image-${CLOUD_PROVIDER} linux-headers-${CLOUD_PROVIDER} linux-tools-${CLOUD_PROVIDER} linux-modules-extra-${CLOUD_PROVIDER} linux-cloud-tools-${CLOUD_PROVIDER}
Pin: version *
Pin-Priority: -1
EOF
    ;;
finalize)
    # Purge the old rolling kernel now that provisioning no longer needs the
    # running kernel's modules. Grub defaults to the highest version present,
    # so the newer series must not remain in the image.
    if [[ ${OLD_KERNEL_SERIES} != "6.8" ]]; then
        apt remove -y --purge "^linux-(image|image-unsigned|modules|modules-extra|headers|tools|cloud-tools)-${OLD_KERNEL_SERIES/./\\.}\..*"
    fi
    apt autoremove -y
    apt clean
    rm -f /var/cache/apt/pkgcache.bin /var/cache/apt/srcpkgcache.bin

    # Fail the build unless the image will boot a 6.8 kernel and only a 6.8
    # kernel. Packer does not reboot mid-build, so the VM is still running the
    # base kernel here -- we assert on the INSTALLED kernel image set (what grub
    # will boot), not `uname -r`. The "linux-image-[0-9]*" glob matches only
    # versioned kernels (e.g. linux-image-6.8.0-1057-aws), never the metas.
    installed_kernels=$(dpkg-query -W -f='${Package} ${db:Status-Status}\n' 'linux-image-[0-9]*' 2>/dev/null | awk '$2=="installed"{print $1}')
    if [[ -z ${installed_kernels} ]]; then
        echo "AV-133308: no kernel image installed; refusing to complete." >&2
        exit 1
    fi
    unexpected_kernels=$(echo "${installed_kernels}" | grep -v '^linux-image-6\.8\.' || true)
    if [[ -n ${unexpected_kernels} ]]; then
        echo "AV-133308: non-6.8 kernel image(s) still installed; refusing to complete:" >&2
        echo "${unexpected_kernels}" >&2
        exit 1
    fi
    echo "AV-133308: verified installed kernel(s): ${installed_kernels//$'\n'/ }"
    ;;
*)
    echo "lock-kernel.sh: unknown mode '${MODE}' (expected install|finalize)" >&2
    exit 1
    ;;
esac
