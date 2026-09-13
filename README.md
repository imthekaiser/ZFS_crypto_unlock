# ZFS_crypto_unlock
A script that auto unlocks your encrypted ZFS datasets on boot.  With general instructions to setup ZFS encryption using keyfiles.

**Proxmox VE:** See [PROXMOX.md](PROXMOX.md) for VM-disk encryption,
boot ordering, service enablement, and failure verification. See
[the Proxmox test results](PROXMOX-TEST-RESULTS.md) for the tested scope.

I created this so if someone stole my server they would also need the USB with the keyfiles to access the encrypted datasets.  To accomplish this I save the keyfiles to the usb and I hide the USB elsewhere, well outside of the case.  I'm not going to get too specific on how I did that, as obfuscation is part of the security here, but you can get quite creative.  
Some ideas:
A USB extension that is hidden
A USB extension that goes to a locked cabinet

You can also serve the keyfiles over networked methods, if your motherboard and system allow for that.  If you don't have to unlock the datasets until after os boot, then you can store the files pretty much anywhere, auch as networked.  Personally, I prefer the physical device.

***Whatever you decide, make sure you have appropriate permissions set for these keyfiles.  They should be protected and treated just like SSH keys.  AND keep a backup!***

## How to use keyfiles with ZFS
### Create Dataset with keyfiles & load
1. Generate the Keyfile (modify save path and filename to suit, I'd save in a folder with same chmod)
```
dd if=/dev/urandom of=/zfs_keyfiles/zfs_keyfilename bs=32 count=1
chmod 0400 /zfs_keyfiles/zfs_keyfilename
chown root:root /zfs_keyfiles/zfs_keyfilename
```
2.  Create a ZFS Dataset that uses the keyfile you just made. Note the file location (you can set other -o options like compession at this point as well)
```
zfs create -o encryption=on -o keylocation=file:///zfs_keyfiles/zfs_keyfilename -o keyformat=raw poolname/datasetname
```
3.  Generic Load keys and Mount Command
```
zfs load-key poolname/datasetname
zfs mount poolname/datasetname
```
## How to use the script on boot
This depends heavily on your system.

### Debian
NOTES:  Make sure to give a unique name to script.service and script.sh

1. Save Your Script in a Suitable Location like /opt
2. make sure the script is excecutable:
```
chmod +x /opt/script.sh
```
3. Reference Your Script in the Service File:  (name appropriately & match script location)
```
nano /etc/systemd/system/script.service
```
add this to the service file:
```
[Unit]
Description=My custom startup script

[Service]
ExecStart=/opt/script.sh

[Install]
WantedBy=multi-user.target
```
4. Check if added as service:
```
systemctl status script.service
``` 
6. Reboot.  Script should now run on boot.  You can confirm by running another:
```
systemctl status script.service
```

### Unraid
1. Install User Scripts Plugin
2. Create New Script and copy/paste ZFS_crypto_unlock.sh
3. Set to "At Startup of Array"

## How to auto mount a usb on boot
This also depends on your system.
### Unraid
1. Install Unassigned Devices Plugin
2. Expand settings for specific USB
3. Configure to automount in the Settings menu

## Maintainance Tasks
### Modify Dataset Keyfile Storage Location
If you move the keyfile, you need to update the dataset with the new location.
1. Unload Key
```
zfs unload-key poolname/datasetname
```
2. Change Key Location
```
zfs change-key -o keylocation=file:///new/path/to/keyfile poolname/datasetname
```
3. Load Key
```
zfs load-key poolname/datasetname
```
4. Verify Change if so desired
```
zfs get all poolname/datasetname | grep keylocation

```

# How was AI used in this script?
AI Was not used to create this script

The supplemental Proxmox instructions, verification helper, and test report were
created with AI assistance and validated against a disposable Proxmox test VM.
