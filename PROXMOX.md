# Proxmox VE setup

These instructions unlock native ZFS encryption on the **Proxmox host**. They do
not unlock LUKS or BitLocker inside a guest, encrypt existing data in place, or
unlock the host's root filesystem from the initramfs.

The original `zfs_crypto_unlock.sh` is unchanged. Its key-loading commands work
on Proxmox, but its original Debian instructions omit service enablement and
storage/guest startup ordering. It also returns success when key loading fails.
The additional `proxmox-verify.sh` checks the required storage before automatic
guest startup can proceed.

## Before changing storage

- Have a verified VM backup and a separate backup of the encryption key.
- Use a maintenance window and retain console access to the Proxmox host.
- Check cluster quorum before rebooting a cluster node.
- Confirm the pool is imported before configuring the unlock service.
- Keep the key outside the encrypted dataset it unlocks. A key stored on the
  host's unencrypted boot disk does not protect against theft of the whole host.
  USB or network key storage needs its own reliable mount configuration.
- These instructions cover ordinary node-local guest startup. HA, migration,
  replication, backup encryption and encrypted root boot need separate testing.

Commands below run as root. Replace `tank`, `pve-encrypted`, `NODE`, `VMID`, and
the key path with your actual values. Do not create a new pool over existing
disks as part of this setup.

## Create encrypted VM storage

Skip creation if you already have the intended encrypted storage. Inspect it:

```bash
zpool status
zfs get -r encryption,encryptionroot,keyformat,keylocation,keystatus tank
```

For a **new** encrypted VM-storage dataset on an existing pool, first mount your
key device at `/mnt/zfs-keys`. If using USB, configure a persistent filesystem
UUID mount in `/etc/fstab` and test that exact mount. Confirm it is mounted before
creating a key so a missing USB does not leave the key on the host by accident:

```bash
mountpoint -q /mnt/zfs-keys
```

Stop if that fails. Set the key filesystem/directory permissions so only root can
access it. Generate a new key without overwriting an existing one:

```bash
install -d -m 0700 /mnt/zfs-keys/keys
(umask 077; set -o noclobber; head -c 32 /dev/urandom > /mnt/zfs-keys/keys/pve.raw)
chmod 0400 /mnt/zfs-keys/keys/pve.raw
zfs create -o encryption=aes-256-gcm -o keyformat=raw \
  -o keylocation=file:///mnt/zfs-keys/keys/pve.raw \
  -o canmount=off -o mountpoint=none tank/pve-encrypted
pvesm add zfspool pve-encrypted --pool tank/pve-encrypted \
  --content images --nodes NODE --sparse 1
```

`canmount=off` is intentional for a parent used only to hold VM zvols. VM disks
created below it inherit its encryption. Zvols are block devices, not mounted
host filesystems. Sparse allocation can overcommit capacity; monitor pool space.

## Move an existing VM disk

ZFS cannot enable encryption in place on an existing unencrypted dataset or
zvol. Move the stopped VM's disk to the encrypted storage instead:

```bash
qm config VMID
qm shutdown VMID --timeout 120
qm status VMID
```

Proceed only when the VM is stopped. Replace `scsi0` with the disk identifier
shown in its configuration:

```bash
qm disk move VMID scsi0 pve-encrypted --delete 0
qm config VMID
zfs get -r encryption,encryptionroot,keystatus tank/pve-encrypted
qm start VMID
```

Validate guest boot and read existing files inside the guest. Move every disk
that needs protection, including separate data, EFI and TPM-state disks where
applicable. The command above covers only `scsi0`.

`--delete 0` retains the old plaintext disk as an unused disk for rollback. It
remains a plaintext copy until you deliberately remove it after validation.
Backups, snapshots and storage remanence also need separate consideration;
deleting a volume is not a secure-erase guarantee.

## Install the scripts

From a reviewed checkout of this repository:

```bash
install -o root -g root -m 0755 zfs_crypto_unlock.sh /usr/local/sbin/zfs-crypto-unlock
install -o root -g root -m 0755 proxmox-verify.sh /usr/local/sbin/zfs-crypto-verify
```

The upstream script scans **all imported pools** for unavailable keys. Audit
other encrypted datasets first. Do not mix unattended operation with datasets
that require an interactive passphrase prompt.

Create `/etc/systemd/system/zfs-crypto-unlock.service`:

```ini
[Unit]
Description=Unlock encrypted ZFS guest storage
Wants=zfs-import.target
After=zfs-import.target zfs-mount.service
Before=pve-guests.service
RequiresMountsFor=/mnt/zfs-keys/keys

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/zfs-crypto-unlock
ExecStartPost=/usr/bin/udevadm settle --timeout=30
ExecStartPost=/usr/local/sbin/zfs-crypto-verify tank/pve-encrypted
TimeoutStartSec=120

[Install]
WantedBy=multi-user.target
```

Change `RequiresMountsFor` to your actual key directory. This requires an
existing working mount configuration; it does not discover or mount an
unconfigured USB device. The pool must also have a working import setup.
`zfs-import.target` ordering alone does not prove that a particular pool imported.
The verifier fails if the configured dataset does not exist.

List every required encrypted storage root on the verifier's command line.
It checks descendant keys, readable zvol devices, and mounted filesystems with
`canmount=on`. It intentionally does not require `canmount=off` or `noauto`
filesystems to mount. Avoid mixing intentionally locked descendants into a
storage tree required at boot.

Create `/etc/systemd/system/pve-guests.service.d/zfs-crypto-unlock.conf`, creating
the parent directory if needed:

```ini
[Unit]
Requires=zfs-crypto-unlock.service
After=zfs-crypto-unlock.service
```

This blocks the node's normal automatic guest-start service if required storage
fails verification. It affects **all** normal autostart guests on that node, not
only encrypted ones. It does not gate manual `qm start`, HA or every API path.
Do not restart `pve-guests.service` to test this on a running node.

With that dependency installed, stopping or restarting the unlock service can
also stop `pve-guests` and trigger guest shutdown. Test service restarts only
during a **node-wide** maintenance window with all guests stopped. Alternatively,
remove only this drop-in and reload systemd before an isolated service test,
then restore it and reload systemd afterward.

Enable and test the unlock service:

```bash
systemctl daemon-reload
systemd-analyze verify /etc/systemd/system/zfs-crypto-unlock.service
systemctl enable --now zfs-crypto-unlock.service
systemctl is-enabled zfs-crypto-unlock.service
systemctl status zfs-crypto-unlock.service --no-pager
journalctl -u zfs-crypto-unlock.service -b --no-pager
```

Simply creating a unit and running `systemctl status` does **not** enable it.
Set the intended VM's `onboot` option only after the storage checks pass:

```bash
qm set VMID --onboot 1
```

## Reboot validation and recovery

Reboot during the maintenance window. After reconnecting, check:

```bash
systemctl status zfs-crypto-unlock.service --no-pager
journalctl -b -u zfs-crypto-unlock.service -u pve-guests.service --no-pager
zfs get -r encryptionroot,keystatus tank/pve-encrypted
qm status VMID
```

Also log into the guest and read a file written before reboot. A green systemd
status or `qm status: running` alone does not prove that the guest booted or that
its data survived.

For a missing-key test with the dependency installed, first shut down all node
guests and every other consumer of the test storage, then confirm the key can
be unloaded. Do not unload keys from live guest storage.
Remove only the test key from its configured location and restart the unlock
service. Verification must fail. Restore the key and restart the service:

```bash
systemctl restart zfs-crypto-unlock.service
qm start VMID
```

Use `restart` to retry an already active oneshot service; `start` may do nothing.
After recovery, explicitly start the intended guests. Do not assume failed boot
dependencies automatically retry when the key becomes available.

To disable this integration, remove only the `pve-guests` drop-in created above,
disable `zfs-crypto-unlock.service`, and run `systemctl daemon-reload`. Disabling
the service does not unload keys, stop running guests or decrypt data.

## Known upstream behavior

- Missing and incorrect keys leave storage locked but the script exits 0. The
  verifier is necessary for meaningful systemd failure status.
- Inherited children trigger a redundant key-load error after the encryption
  root unlocks them. Zvols and `canmount=off` roots trigger mount errors even when
  successfully unlocked. Inspect key status and guest data, not those messages
  alone.
- A filesystem with an already-loaded key but no mount is skipped. Mount that
  filesystem explicitly if intended; the verifier rejects a missing required
  `canmount=on` mount.
- The README's key-location maintenance sequence is wrong: `change-key` requires
  a loaded key. To relocate the same key file, keep its bytes unchanged and use
  `zfs set keylocation=file:///new/path/pve.raw tank/pve-encrypted`. Test access
  during a maintenance window and retain the original key until verified.

## References

- [Upstream script reviewed at 2075454](https://github.com/imthekaiser/ZFS_crypto_unlock/tree/2075454c3f77c7e9deaa86e1eab8d04e0ff412f8)
- [OpenZFS key operations](https://openzfs.github.io/openzfs-docs/man/master/8/zfs-load-key.8.html)
- Installed Proxmox `qm help move_disk`, `pvesm` commands and systemd unit files
  were inspected on the test host. See `PROXMOX-TEST-RESULTS.md` for measured
  versions, results and test limitations.
