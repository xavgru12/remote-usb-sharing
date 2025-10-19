# Remote USB Sharing

## install and configure usbip server on raspberry pi
```
sudo apt-get install usbip
```

list available usb devices

```
usbip list --parsable --local
```

bind devices, so they are available from remote

```
sudo usbip bind -b 2-1
```


check bound devices:
```
ls /sys/bus/usb/drivers/usbip-host/
```

## install and setup Windows client
Install usbip client from: https://github.com/vadimgrn/usbip-win2

Read and follow its instructions as needed.

In server put in remote ip address, select the usb devices.

Save and load usb configs.

If you want to share a SSD devices, you may need to unmount it first.

## install usbip as service
- copy usbip.conf to /etc/modules-load.d/usbip.conf
- copy usbipd.service to /etc/systemd/system/usbipd.service
- systemctl enable --now usbipd
- copy 99-usbip.rules to /etc/udev/rules.d/99-usbip.rules, change the XXXX and YYYY to the product ID and vendor ID you want to exclude from auto binding, then reboot.

Some interesting commands for monitoring setup:
- udevadm control --log-priority=debug and then journalctl -f
- udevadm info -a -p <device path> (device path can be found using usbip list -l, in the form of /sys/devices/pci0000:00/0000:00:1a.0/usb1/1-1/1-1.4 )
- udevadm monitor --property
- udevadm control --reload-rules && udevadm trigger
- udevadm test $(udevadm info -q path -n <device path>) (a different device path in the form of /dev/bus/usb/002/006)

