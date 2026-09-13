# Proxmox compatibility test

Date: 2026-09-13, America/Chicago.

Verdict: The unchanged upstream script unlocks native-ZFS encrypted VM storage
on Proxmox. Its original instructions and error handling are insufficient for
reliable unattended guest startup. With the documented service ordering and
verification, one host reboot successfully unlocked the VM disk, autostarted
the guest, and preserved its in-guest file hash.

## Environment

| Item | Measured configuration |
| --- | --- |
| Host | hv3, bare metal, `systemd-detect-virt` returned `none` |
| Proxmox manager | 9.2.18, build 614bede5d65599c6 |
| Kernel | 7.0.14-16-pve |
| ZFS userspace and module | 2.4.4-pve1 |
| QEMU | 11.0.3 |
| Upstream commit | `2075454c3f77c7e9deaa86e1eab8d04e0ff412f8` |
| Upstream script SHA-256 | `74c6f0078111f88ac43330159a01eba12162391913d6cebc083bafa47802bc59` |
| Disposable pool | `kasa_unlock_test_20260913`, 512 MiB file-backed vdev, `cachefile=none` |
| Encryption | AES-256-GCM, random 32-byte raw key, root-only local key file |
| Test guest | VM 105, CirrOS 0.6.3 x86_64, 1 vCPU, 256 MiB RAM, no NIC |
| Guest disk | 112 MiB zvol, virtio-scsi, BIOS boot, guest ext3 root filesystem |
| Guest image SHA-256 | `7d6355852aeb6dbcd191bcda7cd74f1536cfe5cbf8a10495a7283a8396e4b75b` |

The image checksum matched the [official CirrOS checksum list](https://download.cirros-cloud.net/0.6.3/SHA256SUMS).
The host had no registered guests before the test. Its existing `rpool` was
unencrypted and healthy. All encryption changes were confined to the disposable
pool; no existing VM disks were converted or deleted.

## Results

| Test | Observed result |
| --- | --- |
| Locked encrypted filesystem, correct key | Key loaded, filesystem mounted, synthetic data read back correctly |
| Already unlocked and mounted | No-op, exit 0 |
| Key already loaded, filesystem unmounted | Script skipped it; filesystem remained unmounted |
| Missing key file | Dataset remained locked, errors logged, **script exit 0** |
| Wrong 32-byte key | Dataset remained locked, errors logged, **script exit 0** |
| Restored correct key | Unlock and mount succeeded |
| Encryption root plus inheriting filesystem child | Both mounted; child produced a redundant encryption-root key-load error |
| Independently encrypted zvol | Key loaded and block data read back; script logged a misleading mount failure |
| `canmount=off` encryption root | Key loaded; intentional non-mountability logged as a mount failure |
| README `unload-key` then `change-key` | Failed with `Key must be loaded`, exit 255 |
| Set existing key location with `zfs set`, then `load-key -n` | Passed |
| Move guest boot disk from plaintext ZFS to encrypted ZFS | Proxmox disk move succeeded; destination inherited AES-256-GCM |
| Start guest with its disk key unloaded | Guest stayed stopped; start blocked waiting for the zvol device |
| Run unchanged script, then start the guest | Guest booted; original file and SHA-256 matched |
| Added verifier, no arguments | Exit 2 |
| Added verifier, nonexistent or unencrypted root | Exit 1 |
| Added verifier, required child filesystem unmounted | Exit 1; passed after remount |
| Added verifier, unlocked VM zvol | Passed, including a block-device read |
| Systemd unit, missing key, upstream script plus verifier | Overall unit failed; upstream main process exit 0, verifier exit 1 |
| Host reboot, ordered import/unlock/verify | Passed; encrypted filesystems and volumes accessible afterward |
| Normal Proxmox VM autostart after host reboot | Guest-start service succeeded and test VM started |
| Guest file readback after host reboot | Passed; same SHA-256 as before encryption and before the host reboot |

### Guest disk conversion and data check

The guest first booted with an unencrypted zvol. A synthetic file was written
inside its root filesystem and flushed. With the guest stopped:

```bash
qm disk move 105 scsi0 kasa-unlock-test --delete 0
```

The target storage used `kasa_unlock_test_20260913/canmount-off`. Its new
`vm-105-disk-0` zvol reported that dataset as its `encryptionroot`. The source
plaintext volume remained an unused disk and was not in the boot order.

With the key unloaded, `qm start` did not start the VM. The runner reached its
90-second limit; the separate Proxmox worker was then explicitly cancelled.
This is a blocked-start negative control, not a measured natural Proxmox timeout.
The installed `ZFSPoolPlugin.pm` allows up to 300 seconds for a zvol device link
in a worker task.

After the unchanged script loaded the encryption-root key, the guest booted
from `scsi0`. Reading `/home/cirros/zfs-marker.txt` inside the guest produced:

```text
ZFS-VM-ENCRYPTION-READBACK
462c4ff03764c3cf44e4c2e8b37a119e0ce4d2d3a3ce6a6986cd6adb4bf2624a
```

That SHA-256 matched before the disk move, after the move and manual unlock,
and inside the automatically started guest after the host reboot.

### Reboot integration

One authorized host reboot was performed. The host boot ID changed from
`c05da087-b66c-4f49-ad09-e3d30f915fa9` to
`f22acb54-e2f5-4113-bacf-2abcd6483f8d`.

The test installed a temporary importer for the file-backed pool, a oneshot
unlock service, and a `pve-guests.service` dependency. The importer used
`zpool import -N -d <test-directory> <test-pool>` without loading keys. The unlock
service ran the **unchanged upstream script**, waited for udev, then ran the
additional read-only verifier. No mock ZFS commands or filtered PATH wrapper
were used. Preflight checks established that no unrelated dataset had an
unavailable key.

Measured systemd monotonic timestamps, seconds since boot:

| Event | Seconds |
| --- | ---: |
| Test pool importer completed | 7.434077 |
| Upstream unlock script started | 7.436359 |
| Upstream unlock script completed | 7.890322 |
| Unlock service active, including post-verification | 8.014819 |
| `pve-guests` main process started | 20.923686 |
| `pve-guests` main process completed | 26.350771 |

These timestamps demonstrate ordering for this boot, not a performance benchmark.
The script still emitted its redundant child-key and zvol-mount errors, but the
separate checks confirmed that required storage was usable.

### Failures and test interruptions

An initial synthetic zvol key-unload operation returned `busy` after writing its
marker. Repeating after udev settled succeeded. No forced unload was used.

The networkless CirrOS guest's startup exceeded the original 180-second console
wait. Both baseline and encrypted-disk checks were retried after its startup
completed. Later checks allowed 360 seconds. A virtual RNG was added, and
unneeded cloud metadata probing was disabled before the host reboot. These are
test-fixture adjustments, not changes to the unlock script or encryption.

## What this did not establish

- Physical USB insertion, removal, mount races, or remote key delivery. The
  synthetic test key was a local file on the host's unencrypted root filesystem.
- Security against whole-host theft with the key present. The fixture was for
  compatibility, not a secure production key-storage design.
- Default discovery of a new physical data pool. The file-backed fixture needed
  its own explicit importer; the production pool import must be configured.
- Missing-key behavior across a second host reboot. Service-level failure was
  tested, and the guest dependency was installed for the successful reboot.
- HA startup, live migration, replication, backup/restore encryption, Windows,
  UEFI/TPM disks, containers, or unlocking the host root filesystem.
- Compatibility with other Proxmox or ZFS versions, long-term reliability,
  cryptographic strength, throughput, or I/O latency.
- The exact Reddit comment's requirements. Reddit blocked access, so its text
  was not available and no claims were inferred from it.

## Cleanup

Removed VM 105, both temporary Proxmox storage entries, the synthetic plaintext
and encrypted guest disks, the disposable pool, its key and vdev, the boot
services, the guest-start drop-in, and the remaining test directory. The drop-in
was removed and systemd reloaded before stopping the temporary unlock service,
so cleanup did not stop `pve-guests`.

The final audit verified that the original dataset inventory matched preflight,
`rpool` remained ONLINE with no known data errors, `pve-guests` remained active,
no systemd units were failed, and the cluster was quorate. No test key material
was copied into this repository or retained on hv3.

## Deployment guidance

Use [PROXMOX.md](PROXMOX.md), including the verification helper and guest-start
dependency. The original script alone is not a reliable systemd success signal.

Machine-readable evidence, including post-run ZFS properties, the three guest
readbacks, actual boot units and service timing, is in
[test-results/proxmox-2026-09-13.json](test-results/proxmox-2026-09-13.json).
Encryption key material and unrelated host/cluster inventory are excluded.
