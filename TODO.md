```
sudo dnf install dnf-automatic-reboot-1.0-1.el9.noarch.rpm
Last metadata expiration check: 1:38:34 ago on Sat 23 May 2026 07:19:33 PM CEST.
Dependencies resolved.
==============================================================================================================================
Package                               Architecture            Version                    Repository                     Size
==============================================================================================================================
Installing:
dnf-automatic-reboot                  noarch                  1.0-1.el9                  @commandline                   22 k

Transaction Summary
==============================================================================================================================
Install  1 Package

Total size: 22 k
Installed size: 38 k
Is this ok [y/N]: y
Downloading Packages:
Package dnf-automatic-reboot-1.0-1.el9.noarch.rpm is not signed
Error: GPG check FAILED
```

### Fix: Add --nogpgcheck
`sudo dnf install dnf-automatic-reboot-1.0-1.el9.noarch.rpm`

# 1. Generate a GPG key if you do not have one
```
gpg --batch --gen-key <<EOF
%no-protection
Key-Type: RSA
Key-Length: 4096
Name-Real: ORC4 RPM Signing
Name-Email: root@orc4.ndf.lan
Expire-Date: 0
EOF
```

# 2. Export the public key
`gpg --export -a "ORC4 RPM Signing" > /etc/pki/rpm-gpg/RPM-GPG-KEY-orc4`

# 3. Import it into the RPM keyring
`rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-orc4`

# 4. Configure rpm to use it for signing
# Get the key ID first
`gpg --list-keys "ORC4 RPM Signing" | grep -A1 'pub' | tail -1 | tr -d ' '`

# Add to ~/.rpmmacros
```
cat >> ~/.rpmmacros <<EOF
%_gpg_name ORC4 RPM Signing
%_gpg_path /root/.gnupg
EOF
```

# 5. Sign the RPM
`rpm --addsign ~/rpmbuild/RPMS/noarch/dnf-automatic-reboot-1.0-1.el9.noarch.rpm`

# 6. Verify signature
`rpm --checksig ~/rpmbuild/RPMS/noarch/dnf-automatic-reboot-1.0-1.el9.noarch.rpm`

# 7. Install normally
`dnf install ~/rpmbuild/RPMS/noarch/dnf-automatic-reboot-1.0-1.el9.noarch.rpm`