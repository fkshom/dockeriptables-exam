#!/usr/bin/env bash

set -x

echo -n PREROUTING INPUT FORWARD OUTPUT POSTROUTING | xargs -d " " -n 1 -I {} sudo iptables -w -t filter -P {} ACCEPT
echo -n PREROUTING INPUT FORWARD OUTPUT POSTROUTING | xargs -d " " -n 1 -I {} sudo iptables -w -t nat -P {} ACCEPT
echo -n PREROUTING INPUT FORWARD OUTPUT POSTROUTING | xargs -d " " -n 1 -I {} sudo iptables -w -t mangle -P {} ACCEPT
echo -n PREROUTING INPUT FORWARD OUTPUT POSTROUTING | xargs -d " " -n 1 -I {} sudo iptables -w -t raw -P {} ACCEPT

sudo iptables -w -t filter -F
sudo iptables -w -t nat -F
sudo iptables -w -t mangle -F
sudo iptables -w -t raw -F

sudo iptables -w -t filter -X
sudo iptables -w -t nat -X
sudo iptables -w -t mangle -X
sudo iptables -w -t raw -X
