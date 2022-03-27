#!/usr/bin/env bash

suffix=$1

if [ -z "$suffix" ]; then
  echo "no suffix!"
  exit 1
fi

sudo iptables -nvL -t filter > iptables_nvL_filter_${suffix}.txt
sudo iptables -nvL -t nat    > iptables_nvL_nat_${suffix}.txt
sudo iptables -nvL -t mangle > iptables_nvL_mangle_${suffix}.txt
sudo iptables -nvL -t raw    > iptables_nvL_raw_${suffix}.txt
