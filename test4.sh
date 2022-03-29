#!/usr/bin/env bash

set -x

test_name=test4
container_name=ubuntu

mkdir -p "./${test_name}"
rm -f "./${test_name}/*"

(
    cd "${test_name}"
    sudo systemctl stop docker
    ../reset_iptables.sh
    sudo systemctl start docker
    sudo docker rm -f ${container_name} && true
    sudo docker-compose -f ../test4.docker-compose.yml down

    sudo docker run -d -it --rm --name ${container_name} --publish 3456:3456 ubuntu:20.04 /bin/bash

    ../get_iptables.sh before
    sudo docker-compose -f ../test4.docker-compose.yml up -d

    ../get_iptables.sh after
    sudo docker-compose -f ../test4.docker-compose.yml down
    sudo docker rm -f ${container_name} && true
    
    sdiff -w 150 iptables_nvL_filter_{before,after}.txt | expand -t 8 > iptables_nvL_filter_diff.txt
    sdiff -w 150 iptables_nvL_nat_{before,after}.txt    | expand -t 8 > iptables_nvL_nat_diff.txt
    sdiff -w 150 iptables_nvL_mangle_{before,after}.txt | expand -t 8 > iptables_nvL_mangle_diff.txt
    sdiff -w 150 iptables_nvL_raw_{before,after}.txt    | expand -t 8 > iptables_nvL_raw_diff.txt

    result_filename=result.txt
    (
        echo '```sh'
        echo "# sdiff iptables_nvL_filter_{before,after}.txt"
        cat iptables_nvL_filter_diff.txt
        echo '```'
        echo
        echo '```sh'
        echo "# sdiff iptables_nvL_nat_{before,after}.txt"
        cat iptables_nvL_nat_diff.txt
        echo '```'
        echo

        echo '```sh'
        echo "# sdiff iptables_nvL_mangle_{before,after}.txt"
        cat iptables_nvL_mangle_diff.txt
        echo '```'
        echo

        echo '```sh'
        echo "# sdiff iptables_nvL_raw_{before,after}.txt"
        cat iptables_nvL_raw_diff.txt
        echo '```'
        echo
    ) > "${result_filename}"

)
