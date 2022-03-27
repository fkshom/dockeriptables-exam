# dockerホストでiptables-persistentパッケージやansibleのiptablesモジュールを使うときに気をつけること

## 結論
- iptables-persistent を使うときの注意
  - /etc/default/iptables に
  - Dockerの管理下にある次のチェインはFlushしてはいけない。Dockerが  したり、ルール追加・削除してはならない。Dockerサービス
    - filterテーブル：（build-inチェイン）FORWARD
    - filterテーブル：（user-definedチェイン）DOCKER、DOCKER-ISOLATION-STAGE-1、DOCKER-ISOLATION-STAGE-2 （DOCKER-USERは、チェイン削除しなければ好きに編集して良い）
    - natテーブル：PREROUTING、OUTPUT、POSTROUTING
- ansibleのiptablesモジュール を使うときの注意
  -


/usr/share/netfilter-persistent/plugins.d/15-ip4tables
/etc/default/netfilter-persistent
IPTABLES_RESTORE_NOFLUSH=yes

flushしないと、同じルールが増えていく。。。


sudo apt info iptables-persistent
Package: iptables-persistent
Version: 1.0.14ubuntu1
Priority: optional
Section: universe/admin
Origin: Ubuntu
Maintainer: Ubuntu Developers <ubuntu-devel-discuss@lists.ubuntu.com>
Original-Maintainer: gustavo panizzo <gfa@zumbi.com.ar>
Bugs: https://bugs.launchpad.net/ubuntu/+filebug
Installed-Size: 50.2 kB
Pre-Depends: iptables
Depends: netfilter-persistent (= 1.0.14ubuntu1), debconf (>= 0.5) | debconf-2.0
Download-Size: 6552 B
APT-Sources: http://jp.archive.ubuntu.com/ubuntu focal-updates/universe amd64 Packages
Description: boot-time loader for netfilter rules, iptables plugin
 netfilter-persistent is a loader for netfilter configuration using a
 plugin-based architecture.
 .
 This package contains the iptables and ip6tables plugins.


## ユースケース別ガイドライン
### DocerホストがNATルーターも兼ねている場合

通常は、通過して良いSrcIPアドレス帯をfilterテーブルFORWARDチェインに追加し、natテーブルPOSTROUTINGチェインで`-j MASQUERADE`する場合が多いと思う。

```sh
% sudo iptables -t filter -I FORWARD -s 192.168.2.0/24 -j ACCEPT
% sudo iptables -t filter -nvL FORWARD
Chain FORWARD (policy ACCEPT 0 packets, 0 bytes)
 pkts bytes target     prot opt in     out     source               destination
    0     0 ACCEPT     all  --  *      *       192.168.2.0/24       0.0.0.0/0

% sudo iptables -t nat -I POSTROUTING -o ens33 -j MASQUERADE
% sudo iptables -t nat -nvL POSTROUTING
Chain POSTROUTING (policy ACCEPT 1 packets, 89 bytes)
 pkts bytes target     prot opt in     out     source               destination
    6   483 MASQUERADE  all  --  *      ens33   0.0.0.0/0            0.0.0.0/0
```

しかし、別セクションで説明している通り、filterテーブルFORWARDチェインはdockerの起動時に


とnatテーブルPOSTROUTINGチェインは、DOCKER

# Docker が iptblesに作成するルールの調査

初期状態

```sh
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
```


# test1 初期状態から　docker 起動

初期状態から、dockerを起動したときに、ルールがどのように追加されるのかを確認した。

sdiffの都合上、右側が切れている。必要であればsdiffオプションに -w 200 して実行するか、オリジナルログを参照のこと。

## 結論

- DOCKERによって変更されたテーブル・チェインは次のとおり
  - filterテーブル：
    - FORWARDチェイン：ルール追加
    - DOCKERチェイン：新規作成
    - DOCKER-ISOLATION-STAGE-1チェイン：新規作成
    - DOCKER-ISOLATION-STAGE-1チェイン：新規作成
    - DOCKER-USERチェイン：新規作成
  - natテーブル：
    - PREROUTINGチェイン：ルール追加
    - OUTPUTチェイン：ルール追加
    - POSTROUTINGチェイン：ルール追加
    - DOCKERチェイン：新規作成
  - mangleテーブル：
    - 変更なし
  - rawテーブル：
    - 変更なし
- filter テーブルの　FORWARD チェインのpolicyがDROPになるはずなのだが、なぜかそうなっていない。。。。


## 比較

```sh
# sdiff iptables_nvL_filter_{before,after}.txt
Chain INPUT (policy ACCEPT 2 packets, 113 bytes)              | Chain INPUT (policy ACCEPT 0 packets, 0 bytes)
 pkts bytes target     prot opt in     out     source            pkts bytes target     prot opt in     out     source

Chain FORWARD (policy ACCEPT 0 packets, 0 bytes)                Chain FORWARD (policy ACCEPT 0 packets, 0 bytes)
 pkts bytes target     prot opt in     out     source            pkts bytes target     prot opt in     out     source
                                                              >     0     0 DOCKER-USER  all  --  *      *       0.0.0.0/0
                                                              >     0     0 DOCKER-ISOLATION-STAGE-1  all  --  *      *
                                                              >     0     0 ACCEPT     all  --  *      docker0  0.0.0.0/0
                                                              >     0     0 DOCKER     all  --  *      docker0  0.0.0.0/0
                                                              >     0     0 ACCEPT     all  --  docker0 !docker0  0.0.0.0/0
                                                              >     0     0 ACCEPT     all  --  docker0 docker0  0.0.0.0/0

Chain OUTPUT (policy ACCEPT 2 packets, 113 bytes)             | Chain OUTPUT (policy ACCEPT 0 packets, 0 bytes)
 pkts bytes target     prot opt in     out     source            pkts bytes target     prot opt in     out     source
                                                              >
                                                              > Chain DOCKER (1 references)
                                                              >  pkts bytes target     prot opt in     out     source
                                                              >
                                                              > Chain DOCKER-ISOLATION-STAGE-1 (1 references)
                                                              >  pkts bytes target     prot opt in     out     source
                                                              >     0     0 DOCKER-ISOLATION-STAGE-2  all  --  docker0 !docke
                                                              >     0     0 RETURN     all  --  *      *       0.0.0.0/0
                                                              >
                                                              > Chain DOCKER-ISOLATION-STAGE-2 (1 references)
                                                              >  pkts bytes target     prot opt in     out     source
                                                              >     0     0 DROP       all  --  *      docker0  0.0.0.0/0
                                                              >     0     0 RETURN     all  --  *      *       0.0.0.0/0
                                                              >
                                                              > Chain DOCKER-USER (1 references)
                                                              >  pkts bytes target     prot opt in     out     source
                                                              >     0     0 RETURN     all  --  *      *       0.0.0.0/0
```

```sh
# sdiff iptables_nvL_nat_{before,after}.txt
Chain PREROUTING (policy ACCEPT 0 packets, 0 bytes)             Chain PREROUTING (policy ACCEPT 0 packets, 0 bytes)
 pkts bytes target     prot opt in     out     source            pkts bytes target     prot opt in     out     source
                                                              >     0     0 DOCKER     all  --  *      *       0.0.0.0/0

Chain INPUT (policy ACCEPT 0 packets, 0 bytes)                  Chain INPUT (policy ACCEPT 0 packets, 0 bytes)
 pkts bytes target     prot opt in     out     source            pkts bytes target     prot opt in     out     source

Chain OUTPUT (policy ACCEPT 0 packets, 0 bytes)                 Chain OUTPUT (policy ACCEPT 0 packets, 0 bytes)
 pkts bytes target     prot opt in     out     source            pkts bytes target     prot opt in     out     source
                                                              >     0     0 DOCKER     all  --  *      *       0.0.0.0/0

Chain POSTROUTING (policy ACCEPT 0 packets, 0 bytes)            Chain POSTROUTING (policy ACCEPT 0 packets, 0 bytes)
 pkts bytes target     prot opt in     out     source            pkts bytes target     prot opt in     out     source
                                                              >     0     0 MASQUERADE  all  --  *      !docker0  172.17.0.0/
                                                              >
                                                              > Chain DOCKER (2 references)
                                                              >  pkts bytes target     prot opt in     out     source
                                                              >     0     0 RETURN     all  --  docker0 *       0.0.0.0/0
```

```sh
# sdiff iptables_nvL_mangle_{before,after}.txt
Chain PREROUTING (policy ACCEPT 2 packets, 113 bytes)         | Chain PREROUTING (policy ACCEPT 4 packets, 268 bytes)
 pkts bytes target     prot opt in     out     source            pkts bytes target     prot opt in     out     source

Chain INPUT (policy ACCEPT 2 packets, 113 bytes)              | Chain INPUT (policy ACCEPT 4 packets, 268 bytes)
 pkts bytes target     prot opt in     out     source            pkts bytes target     prot opt in     out     source

Chain FORWARD (policy ACCEPT 0 packets, 0 bytes)                Chain FORWARD (policy ACCEPT 0 packets, 0 bytes)
 pkts bytes target     prot opt in     out     source            pkts bytes target     prot opt in     out     source

Chain OUTPUT (policy ACCEPT 2 packets, 113 bytes)               Chain OUTPUT (policy ACCEPT 2 packets, 113 bytes)
 pkts bytes target     prot opt in     out     source            pkts bytes target     prot opt in     out     source

Chain POSTROUTING (policy ACCEPT 2 packets, 113 bytes)          Chain POSTROUTING (policy ACCEPT 2 packets, 113 bytes)
 pkts bytes target     prot opt in     out     source            pkts bytes target     prot opt in     out     source
```

```sh
# sdiff iptables_nvL_raw_{before,after}.txt
Chain PREROUTING (policy ACCEPT 2 packets, 113 bytes)         | Chain PREROUTING (policy ACCEPT 4 packets, 268 bytes)
 pkts bytes target     prot opt in     out     source            pkts bytes target     prot opt in     out     source

Chain OUTPUT (policy ACCEPT 2 packets, 113 bytes)               Chain OUTPUT (policy ACCEPT 2 packets, 113 bytes)
 pkts bytes target     prot opt in     out     source            pkts bytes target     prot opt in     out     source
```




# test2 docker がどのchainをflushしたり、既存ルールの前と後ろのどちらにルールを挿入するのかの確認

初期状態にしたあと、すべてのチェインにACCEPTルールを挿入し、dockerを起動させた。

## 結論
- どのチェインもFLUSHされなかった
- DOCKERによって変更されたテーブル・チェインは次のとおり
  - filterテーブル
    - FORWARDチェイン：既存ルールの前にDOCKER関連ルールが挿入された
  - natテーブル
    - PREROUTINGチェイン：既存ルールの後にDOCKER関連ルールが挿入された
    - OUTPUTチェイン：既存ルールの後にDOCKER関連ルールが挿入された
    - POSTROUTINGチェン：既存ルールの前にDOCKER関連ルールが挿入された

## 比較


```sh
# sdiff iptables_nvL_filter_{before,after}.txt
Chain INPUT (policy ACCEPT 0 packets, 0 bytes)                  Chain INPUT (policy ACCEPT 0 packets, 0 bytes)
 pkts bytes target     prot opt in     out     source            pkts bytes target     prot opt in     out     source
    0     0 ACCEPT     all  --  *      *       0.0.0.0/0            0     0 ACCEPT     all  --  *      *       0.0.0.0/0

Chain FORWARD (policy ACCEPT 0 packets, 0 bytes)                Chain FORWARD (policy ACCEPT 0 packets, 0 bytes)
 pkts bytes target     prot opt in     out     source            pkts bytes target     prot opt in     out     source
                                                              >     0     0 DOCKER-USER  all  --  *      *       0.0.0.0/0
                                                              >     0     0 DOCKER-ISOLATION-STAGE-1  all  --  *      *
                                                              >     0     0 ACCEPT     all  --  *      docker0  0.0.0.0/0
                                                              >     0     0 DOCKER     all  --  *      docker0  0.0.0.0/0
                                                              >     0     0 ACCEPT     all  --  docker0 !docker0  0.0.0.0/0
                                                              >     0     0 ACCEPT     all  --  docker0 docker0  0.0.0.0/0
    0     0 ACCEPT     all  --  *      *       0.0.0.0/0            0     0 ACCEPT     all  --  *      *       0.0.0.0/0

Chain OUTPUT (policy ACCEPT 0 packets, 0 bytes)                 Chain OUTPUT (policy ACCEPT 0 packets, 0 bytes)
 pkts bytes target     prot opt in     out     source            pkts bytes target     prot opt in     out     source
    0     0 ACCEPT     all  --  *      *       0.0.0.0/0            0     0 ACCEPT     all  --  *      *       0.0.0.0/0
                                                              >
                                                              > Chain DOCKER (1 references)
                                                              >  pkts bytes target     prot opt in     out     source
                                                              >
                                                              > Chain DOCKER-ISOLATION-STAGE-1 (1 references)
                                                              >  pkts bytes target     prot opt in     out     source
                                                              >     0     0 DOCKER-ISOLATION-STAGE-2  all  --  docker0 !docke
                                                              >     0     0 RETURN     all  --  *      *       0.0.0.0/0
                                                              >
                                                              > Chain DOCKER-ISOLATION-STAGE-2 (1 references)
                                                              >  pkts bytes target     prot opt in     out     source
                                                              >     0     0 DROP       all  --  *      docker0  0.0.0.0/0
                                                              >     0     0 RETURN     all  --  *      *       0.0.0.0/0
                                                              >
                                                              > Chain DOCKER-USER (1 references)
                                                              >  pkts bytes target     prot opt in     out     source
                                                              >     0     0 RETURN     all  --  *      *       0.0.0.0/0
```

```sh
# sdiff iptables_nvL_nat_{before,after}.txt
Chain PREROUTING (policy ACCEPT 0 packets, 0 bytes)             Chain PREROUTING (policy ACCEPT 0 packets, 0 bytes)
 pkts bytes target     prot opt in     out     source            pkts bytes target     prot opt in     out     source
    0     0 ACCEPT     all  --  *      *       0.0.0.0/0            0     0 ACCEPT     all  --  *      *       0.0.0.0/0
                                                              >     0     0 DOCKER     all  --  *      *       0.0.0.0/0

Chain INPUT (policy ACCEPT 0 packets, 0 bytes)                  Chain INPUT (policy ACCEPT 0 packets, 0 bytes)
 pkts bytes target     prot opt in     out     source            pkts bytes target     prot opt in     out     source
    0     0 ACCEPT     all  --  *      *       0.0.0.0/0            0     0 ACCEPT     all  --  *      *       0.0.0.0/0

Chain OUTPUT (policy ACCEPT 0 packets, 0 bytes)                 Chain OUTPUT (policy ACCEPT 0 packets, 0 bytes)
 pkts bytes target     prot opt in     out     source            pkts bytes target     prot opt in     out     source
    0     0 ACCEPT     all  --  *      *       0.0.0.0/0            0     0 ACCEPT     all  --  *      *       0.0.0.0/0
                                                              >     0     0 DOCKER     all  --  *      *       0.0.0.0/0

Chain POSTROUTING (policy ACCEPT 0 packets, 0 bytes)            Chain POSTROUTING (policy ACCEPT 0 packets, 0 bytes)
 pkts bytes target     prot opt in     out     source            pkts bytes target     prot opt in     out     source
                                                              >     0     0 MASQUERADE  all  --  *      !docker0  172.17.0.0/
    0     0 ACCEPT     all  --  *      *       0.0.0.0/0            0     0 ACCEPT     all  --  *      *       0.0.0.0/0
                                                              >
                                                              > Chain DOCKER (2 references)
                                                              >  pkts bytes target     prot opt in     out     source
                                                              >     0     0 RETURN     all  --  docker0 *       0.0.0.0/0
```

```sh
# sdiff iptables_nvL_mangle_{before,after}.txt
Chain PREROUTING (policy ACCEPT 0 packets, 0 bytes)             Chain PREROUTING (policy ACCEPT 0 packets, 0 bytes)
 pkts bytes target     prot opt in     out     source            pkts bytes target     prot opt in     out     source
    0     0 ACCEPT     all  --  *      *       0.0.0.0/0            0     0 ACCEPT     all  --  *      *       0.0.0.0/0

Chain INPUT (policy ACCEPT 0 packets, 0 bytes)                  Chain INPUT (policy ACCEPT 0 packets, 0 bytes)
 pkts bytes target     prot opt in     out     source            pkts bytes target     prot opt in     out     source
    0     0 ACCEPT     all  --  *      *       0.0.0.0/0            0     0 ACCEPT     all  --  *      *       0.0.0.0/0

Chain FORWARD (policy ACCEPT 0 packets, 0 bytes)                Chain FORWARD (policy ACCEPT 0 packets, 0 bytes)
 pkts bytes target     prot opt in     out     source            pkts bytes target     prot opt in     out     source
    0     0 ACCEPT     all  --  *      *       0.0.0.0/0            0     0 ACCEPT     all  --  *      *       0.0.0.0/0

Chain OUTPUT (policy ACCEPT 0 packets, 0 bytes)                 Chain OUTPUT (policy ACCEPT 0 packets, 0 bytes)
 pkts bytes target     prot opt in     out     source            pkts bytes target     prot opt in     out     source
    0     0 ACCEPT     all  --  *      *       0.0.0.0/0            0     0 ACCEPT     all  --  *      *       0.0.0.0/0

Chain POSTROUTING (policy ACCEPT 0 packets, 0 bytes)            Chain POSTROUTING (policy ACCEPT 0 packets, 0 bytes)
 pkts bytes target     prot opt in     out     source            pkts bytes target     prot opt in     out     source
    0     0 ACCEPT     all  --  *      *       0.0.0.0/0            0     0 ACCEPT     all  --  *      *       0.0.0.0/0
```

```sh
# sdiff iptables_nvL_raw_{before,after}.txt
Chain PREROUTING (policy ACCEPT 0 packets, 0 bytes)             Chain PREROUTING (policy ACCEPT 0 packets, 0 bytes)
 pkts bytes target     prot opt in     out     source            pkts bytes target     prot opt in     out     source
    0     0 ACCEPT     all  --  *      *       0.0.0.0/0            0     0 ACCEPT     all  --  *      *       0.0.0.0/0

Chain OUTPUT (policy ACCEPT 0 packets, 0 bytes)                 Chain OUTPUT (policy ACCEPT 0 packets, 0 bytes)
 pkts bytes target     prot opt in     out     source            pkts bytes target     prot opt in     out     source
    0     0 ACCEPT     all  --  *      *       0.0.0.0/0            0     0 ACCEPT     all  --  *      *       0.0.0.0/0
```
