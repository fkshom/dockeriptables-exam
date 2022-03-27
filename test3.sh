#!/usr/bin/env bash

set -x

test_name=test2

mkdir -p "./${test_name}"
rm -f "./${test_name}/*"

(
    cd "${test_name}"
    sudo systemctl stop docker
    ../reset_iptables.sh

    echo PREROUTING INPUT FORWARD OUTPUT POSTROUTING | xargs -n 1 sudo iptables -t filter -j ACCEPT -I
    echo PREROUTING INPUT FORWARD OUTPUT POSTROUTING | xargs -n 1 sudo iptables -t nat -j ACCEPT -I
    echo PREROUTING INPUT FORWARD OUTPUT POSTROUTING | xargs -n 1 sudo iptables -t mangle -j ACCEPT -I
    echo PREROUTING INPUT FORWARD OUTPUT POSTROUTING | xargs -n 1 sudo iptables -t raw -j ACCEPT -I

    ../get_iptables.sh before
    sudo systemctl start docker
    ../get_iptables.sh after

    sdiff iptables_nvL_filter_{before,after}.txt | expand -t 8 > iptables_nvL_filter_diff.txt
    sdiff iptables_nvL_nat_{before,after}.txt    | expand -t 8 > iptables_nvL_nat_diff.txt
    sdiff iptables_nvL_mangle_{before,after}.txt | expand -t 8 > iptables_nvL_mangle_diff.txt
    sdiff iptables_nvL_raw_{before,after}.txt    | expand -t 8 > iptables_nvL_raw_diff.txt
)
