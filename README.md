# dynufw

This project contains a number of scripts for protecting a host through a `ufw`
based firewall. These are

* `fw.sh` facilitates the installation of `ufw` on both debian(-derivatives) and
  alpine. In addition, it sets ups a number of "fast" rules for a ports and
  arranges for a cronjob to update rules that are specific to dynamic hosts.
* `ufw-dynamic-host-update.sh` reads its configuration from a system-wide file
  and will resolve the host names contained in that file to IP addresses and
  update `ufw` rules whenever the IP has changed.
* `ufw-clean.sh` cleans away all `ufw` based rules at the `iptables` level.

Some of these scripts originate from elsewhere and have been modified across
time to suit my own needs. I have lost track of their origin and I hope their
original authors allow their republication here. Please raise an issue!
