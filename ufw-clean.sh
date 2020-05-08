#! /usr/bin/env sh

set -eu

iptables --flush
for i in $(iptables --list | grep '^Chain' | grep -Eo "ufw-[a-z-]+" | xargs echo); do
  iptables --delete-chain "$i"
done

ip6tables --flush
for i in $(ip6tables --list | grep '^Chain' | grep -Eo "ufw6-[a-z-]+" | xargs echo); do
  ip6tables --delete-chain "$i"
done
