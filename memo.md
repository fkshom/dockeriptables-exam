# dockerホストでiptables-persistentパッケージを使うときに気をつけること

## 前提

- Ubuntu 20.04 Server
- Docker 20.10.13
- iptables-persistent 10.0.14
- docker-compose version 1.27.4, build 40524192
```

## 背景
dockerホストへのSSH接続を制限したいなどで、iptables-persistentパッケージを利用していました。
しかし、iptalbesの設定を変更しようとして`/etc/iptables/rules.v4`を編集して`netfilter-persistent reload` すると、外部からdockerコンテナへの通信ができなくなってしまいました。
dockerはiptablesを使ってコンテナ内外の通信を制御しており、dockerによってFORWARDINGチェインに重要なルールが追加されていたからです。

この記事では、dockerホストでiptables-persistentを使うときに、うまく共存する方法を紹介します。

## 結論
dockerホストでiptables-persistent を使うときは、次のことに注意します。

- `netfilter-persistent save` を使ってはいけない
  - 現在のコンテナへのフォワーディングルールなどの、保存したくないDocker関連のルールも保存されてしまうため
- /etc/iptables/rules.v4 は手動で作成しよう
  - テンプレートを下記で提供します
- /etc/default/iptables を編集し、`IPTABLES_RESTORE_NOFLUSH=yes`としておくこと。
  - これによって、`netfilter-persistent reload`時にチェインがFlush(全ルール削除)されなくなる。
  - Flushしたいチェインを利用者側で制御できるようになる
- Dockerの管理下にある次のチェインはFlushしてはいけない。
  - filterテーブル：（built-inチェイン）FORWARD
  - filterテーブル：（user-definedチェイン）DOCKER、DOCKER-ISOLATION-STAGE-1、DOCKER-ISOLATION-STAGE-2 （DOCKER-USERは、チェイン削除しなければ好きに編集して良い）
  - natテーブル：（built-inチェイン）PREROUTING、OUTPUT、POSTROUTING
  - natテーブル：（user-definedチェイン）DOCKER
- ユーザーがfilterテーブルFORWARDチェインにルールを追加したい場合は、代わりに次のチェインに対して追加する
  - filterテーブル：DOCKER-USER

## テンプレート

```
#========================================
*mangle
#========================================
# 自由にルールを追加してよい
:PREROUTING ACCEPT [0:0]
:INPUT ACCEPT [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]
COMMIT

#========================================
*raw
#========================================
# 自由にルールを追加してよい
:PREROUTING ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
COMMIT

#========================================
*filter
#========================================
:INPUT ACCEPT [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:DOCKER - [0:0]
:DOCKER-ISOLATION-STAGE-1 - [0:0]
:DOCKER-ISOLATION-STAGE-2 - [0:0]
:DOCKER-USER - [0:0]
-A FORWARD -j DOCKER-USER
-A FORWARD -j DOCKER-ISOLATION-STAGE-1
-A FORWARD -o docker0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
-A FORWARD -o docker0 -j DOCKER
-A FORWARD -i docker0 ! -o docker0 -j ACCEPT
-A FORWARD -i docker0 -o docker0 -j ACCEPT
-A DOCKER-ISOLATION-STAGE-1 -i docker0 ! -o docker0 -j DOCKER-ISOLATION-STAGE-2
-A DOCKER-ISOLATION-STAGE-1 -j RETURN
-A DOCKER-ISOLATION-STAGE-2 -o docker0 -j DROP
-A DOCKER-ISOLATION-STAGE-2 -j RETURN
-A DOCKER-USER -j RETURN
COMMIT

#========================================
*nat
#========================================
:PREROUTING ACCEPT [0:0]
:INPUT ACCEPT [0:0]
:OUTPUT ACCEPT [1:73]
:POSTROUTING ACCEPT [1:73]
:DOCKER - [0:0]
-A PREROUTING -m addrtype --dst-type LOCAL -j DOCKER
-A OUTPUT ! -d 127.0.0.0/8 -m addrtype --dst-type LOCAL -j DOCKER
-A POSTROUTING -s 172.17.0.0/16 ! -o docker0 -j MASQUERADE
-A DOCKER -i docker0 -j RETURN
COMMIT




*filter
#========================================

-P INPUT ACCEPT
-F INPUT

# ここにfilterテーブルINPUTチェインのユーザールールを書く

-P FORWARD DROP
-F FORWARD
-A FORWARD -i ens33 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
-A FORWARD -o ens33 -j ACCEPT

# ここにfilterテーブルFORWARDチェインのユーザールールを書く

-P OUTPUT ACCEPT
# ここにfilterテーブルOUTPUTチェインのユーザールールを書く


-N DOCKER
-N DOCKER-ILOSATION-STAGE-1
-N DOCKER-ILOSATION-STAGE-2
-N DOCKER-USER

COMMIT

#========================================
*nat
#========================================
:PREROUTING ACCEPT [1:325]
:INPUT ACCEPT [1:325]
:OUTPUT ACCEPT [38:3998]
:POSTROUTING ACCEPT [14:2144]
-A POSTROUTING -o ens33 -j MASQUERADE
COMMIT

#========================================
*mangle
#========================================
-F PREROUTING
-F INPUT
-F INPUT
-F FORWARD
-F OUTPUT
-F POSTROUTING

#========================================
*raw
#========================================
-F PREROUTING
-F OUTPUT

```



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


# test3 コンテナ起動に伴って追加されるルールの確認

初期状態にてdockerサービスを起動したあと、適当なコンテナを起動した

コンテナ起動コマンド
```sh
# ポート3456をポート転送する
docker run -d -it --rm --name ubuntu --publish 3456:3456 ubuntu:20.04 /bin/bash
```

## 結論
-

## 比較（コンテナ起動前後）

# test3 コンテナ起動に伴って追加されるルールの確認

初期状態にてdockerサービスを起動したあと、適当なコンテナを起動したのち、さらにdocker-composeでコンテナを起動した

コンテナ起動コマンド
```sh
# ポート3456をポート転送するコンテナを起動
docker run -d -it --rm --name ubuntu --publish 3456:3456 ubuntu:20.04 /bin/bash

# ポート4567をポート転送するコンテナを起動
sudo docker-compose -f ../test4.docker-compose.yml up -d
```

## 結論
-

## 比較（docker-composeによるコンテナ起動前後）
