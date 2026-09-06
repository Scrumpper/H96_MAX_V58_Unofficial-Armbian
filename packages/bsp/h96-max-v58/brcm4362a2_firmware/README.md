# BCM4362A2.hcd

Broadcom Bluetooth firmware/patch blob for onboard **BCM4362A2** UART Bluetooth
radio (paired with PCIe **AP6275P/BCM43752** WiFi 6 half). Every prior build of
this board wrongly assumed chip was a BCM4345C0 and loaded wrong firmware,
which is why Bluetooth failed to come up with no error logged. `h96-bt-attach.py` loads this file,
attaches H4 line discipline, and brings `hci0` up at boot.

Vendor-supplied binary blob, redistributed here (as-is) so a from-scratch build has
everything it needs, same as this board's WiFi firmware ships through distro's own
`linux-firmware` package rather than a custom blob.
