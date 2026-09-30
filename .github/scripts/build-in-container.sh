#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# build-in-container.sh
# ---------------------------------------------------------------------------
# Builds and checks the package inside quay.io/rockylinux/rockylinux:${EL},
# started by .github/workflows/ci.yml with the checkout mounted at /src.
#
#   1. make dist: lint (shellcheck runs in the lint job) and the test suite,
#      then the source tarball.  The container's /tmp allows exec, so the
#      tests marked needs-exec run here.
#   2. rpmbuild -ba with the snapshot Release; %check runs the suite again
#      from the extracted tarball.
#   3. A normal install must be refused by the %pre gate: a container is not
#      booted by systemd.  This proves the gate runs and refuses.
#   4. An install without scriptlets must resolve every dependency from the EL
#      repositories and pass rpm -V.
#
# Environment: EL (8 or 9), RPM_RELEASE (0.<run>.git<sha>).
# ---------------------------------------------------------------------------
set -euo pipefail
IFS=$'\n\t'

: "${EL:?EL must name the Enterprise Linux major}"
: "${RPM_RELEASE:?RPM_RELEASE must hold the snapshot Release}"

readonly SOURCE_DIRECTORY=/src
readonly TOP_DIRECTORY="${SOURCE_DIRECTORY}/rpmbuild"
readonly PACKAGE_NAME=dnf-automatic-reboot

dnf -y -q install rpm-build make gawk util-linux tar gzip findutils systemd-rpm-macros >/dev/null

make -C "${SOURCE_DIRECTORY}" dist

rpmbuild -ba "${SOURCE_DIRECTORY}/${PACKAGE_NAME}.spec" \
    --define "_topdir ${TOP_DIRECTORY}" \
    --define "_sourcedir ${SOURCE_DIRECTORY}" \
    --define "_specdir ${SOURCE_DIRECTORY}" \
    --define "dist .el${EL}" \
    --define "rpm_release ${RPM_RELEASE}"

package_file=$(find "${TOP_DIRECTORY}/RPMS/noarch" -name "${PACKAGE_NAME}-*.el${EL}.noarch.rpm" | head -n 1)
if [[ -z "${package_file}" ]]; then
    echo "::error::no ${PACKAGE_NAME} .el${EL} noarch RPM was built"
    exit 1
fi
echo "built ${package_file}"

# A container is not booted by systemd, so the gate must refuse it.
gate_exit_code=0
gate_output=$(dnf -y install "${package_file}" 2>&1) || gate_exit_code=$?
if [[ "${gate_exit_code}" -eq 0 ]]; then
    printf '%s\n' "${gate_output}"
    echo "::error::the %pre gate accepted a container"
    exit 1
fi
if ! grep -q 'systemd is not the running init' <<< "${gate_output}"; then
    printf '%s\n' "${gate_output}"
    echo "::error::the install failed, but not with the %pre gate's refusal"
    exit 1
fi
echo "%pre gate refused the container, as expected"

dnf -y install --setopt=tsflags=noscripts "${package_file}"
rpm -V "${PACKAGE_NAME}"
echo "dependencies resolved and the payload verifies"
