# dockerホストでiptables-persistentパッケージを使うときに気をつけること

## 前提

- Ubuntu 20.04 Server
- Docker 20.10.13
- iptables-persistent 10.0.14
- docker-compose version 1.27.4, build 40524192


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
- Dockerの管理下にあるチェインはFlushしてはいけない。
  - filterテーブル：（built-inチェイン）FORWARD
  - filterテーブル：（user-definedチェイン）DOCKER、DOCKER-ISOLATION-STAGE-1、DOCKER-ISOLATION-STAGE-2 （DOCKER-USERは、チェイン削除しなければ好きに編集して良い）
  - natテーブル：（built-inチェイン）PREROUTING、OUTPUT、POSTROUTING
  - natテーブル：（user-definedチェイン）DOCKER
- ユーザーがfilterテーブルFORWARDチェインにルールを追加したい場合は、代わりに次のチェインに対して追加する
  - filterテーブル：DOCKER-USER


|        |                          | Dockerが利用 | Dockerによるルール追加場所 | ユーザーによるFlush | ユーザーによるルール追加 | 備考                              |
|--------|--------------------------|-----------|------------------|--------------|--------------|----------------------------------------------------------------|
| filter | INPUT                    |           |                  | flush可       | 可            |                                                                |
| ^      | FORWARD                  | yes       | 先頭             |               | 末尾にのみ可       | DOCKER-*ルールへのジャンプルールも追加される                                     |
| ^      | OUTPUT                   |           |                  | flush可       | 可            |                                                                |
| ^      | DOCKER                   | yes       | any              |              | 不可           |                                                                |
| ^      | DOCKER-ISOLATION-STAGE-1 | yes       | any              |              | 不可           |                                                                |
| ^      | DOCKER-ISOLATION-STAGE-2 | yes       | any              |              | 不可           |                                                                |
| ^      | DOCKER-USER              |           |                  | flush可       | 可            | FORWARDINGの末尾のDockerルールを使うため、ユーザー定義ルールはのactionはRETURNにすること。    |
| nat    | PREROUTING               | yes       | 末尾               |              | 先頭にのみ可       | 末尾のDockerルールを使うため、ユーザー定義ルールのin_interfaceにdocker0を指定してはいけない     |
| ^      | INPUT                    |           |                  | flush可       | 可            |                                                                |
| ^      | OUTPUT                   | yes       | 末尾               |              | 先頭にのみ可       | 末尾のDockerルールを使うため、ユーザー定義ルールのin_interfaceにdocker0を指定してはいけない     |
| ^      | POSTROUTING              | yes       | 先頭               |              | 末尾にのみ可       | 当ホスト経由で外部にパケットルーティングする際のMASQUERADEルールは定義不要（Dockerが同様のルールを追加する） |
| ^      | DOCKER                   | yes       | any              |              | 不可           |                                                                |
| mangle | PREROUTING               |           |                  | flush可       | 可            |                                                                |
| ^      | INPUT                    |           |                  | flush可       | 可            |                                                                |
| ^      | FORWARD                  |           |                  | flush可       | 可            |                                                                |
| ^      | OUTPUT                   |           |                  | flush可       | 可            |                                                                |
| ^      | POSTROUTING              |           |                  | flush可       | 可            |                                                                |
| raw    | PREROUTING               |           |                  | flush可       | 可            |                                                                |
| ^      | OUTPUT                   |           |                  | flush可       | 可            |                                                                |

## テンプレート

```
#========================================
*filter
#========================================
# 自由にルールを追加してよい(reload時にflushする)
:INPUT ACCEPT [0:0]

# 末尾にのみルールを追加してよい（-A）が、reload時にflushしてはいけない
:FORWARD ACCEPT [0:0]

# 自由にルールを追加してよい(reload時にflushする)
:OUTPUT ACCEPT [0:0]

# ルール追加してはいけない
:DOCKER - [0:0]
:DOCKER-ISOLATION-STAGE-1 - [0:0]
:DOCKER-ISOLATION-STAGE-2 - [0:0]

# 自由にルールを追加してよい(reload時にflushする)
# ルールがdockerコンテナに関係する場合はactionとしてRETURNを使うこと
:DOCKER-USER - [0:0]
-F DOCKER-USER
-A DOCKER-USER -j RETURN
COMMIT

#========================================
*nat
#========================================
# 先頭にのみルールを追加してよい（-I）が、reload時にflushしてはいけない
# 末尾にはDockerがルールを追加するため、ユーザー定義ルールはRETURNを使わなければならない
:PREROUTING ACCEPT [0:0]

# 自由にルールを追加してよい(reload時にflushする)
:INPUT ACCEPT [0:0]
-F INPUT

# 先頭にのみルールを追加してよい（-I）が、reload時にflushしてはいけない
# 末尾にはDockerがルールを追加するため、ユーザー定義ルールはRETURNを使わなければならない
:OUTPUT ACCEPT [0:0]

# 末尾にのみルールを追加してよい（-A）が、reload時にflushしてはいけない
:POSTROUTING ACCEPT [0:0]
-A POSTROUTING -o ens33 -j MASQUERADE
:DOCKER - [0:0]
COMMIT

#========================================
*mangle
# 自由にルールを追加してよい(reload時にflashする)
#========================================
:PREROUTING ACCEPT [0:0]
-F PREROUTING
:INPUT ACCEPT [0:0]
-F INPUT
:FORWARD ACCEPT [0:0]
-F FORWARD
:OUTPUT ACCEPT [0:0]
-F OUTPUT
:POSTROUTING ACCEPT [0:0]
-F POSTROUTING
COMMIT

#========================================
*raw
# 自由にルールを追加してよい(reload時にflashする)
#========================================
:PREROUTING ACCEPT [0:0]
-F PREROUTING
:OUTPUT ACCEPT [0:0]
-F OUTPUT
COMMIT
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

```sh
# sdiff iptables_nvL_filter_{before,after}.txt
Chain INPUT (policy ACCEPT 8 packets, 552 bytes)                          |     Chain INPUT (policy ACCEPT 17 packets, 2223 bytes)
 pkts bytes target     prot opt in     out     source               de           pkts bytes target     prot opt in     out     source               de

Chain FORWARD (policy ACCEPT 0 packets, 0 bytes)                                Chain FORWARD (policy ACCEPT 0 packets, 0 bytes)
 pkts bytes target     prot opt in     out     source               de           pkts bytes target     prot opt in     out     source               de
    0     0 DOCKER-USER  all  --  *      *       0.0.0.0/0                          0     0 DOCKER-USER  all  --  *      *       0.0.0.0/0
    0     0 DOCKER-ISOLATION-STAGE-1  all  --  *      *       0.0.0.0/              0     0 DOCKER-ISOLATION-STAGE-1  all  --  *      *       0.0.0.0/
    0     0 ACCEPT     all  --  *      docker0  0.0.0.0/0            0              0     0 ACCEPT     all  --  *      docker0  0.0.0.0/0            0
    0     0 DOCKER     all  --  *      docker0  0.0.0.0/0            0              0     0 DOCKER     all  --  *      docker0  0.0.0.0/0            0
    0     0 ACCEPT     all  --  docker0 !docker0  0.0.0.0/0                         0     0 ACCEPT     all  --  docker0 !docker0  0.0.0.0/0
    0     0 ACCEPT     all  --  docker0 docker0  0.0.0.0/0                          0     0 ACCEPT     all  --  docker0 docker0  0.0.0.0/0

Chain OUTPUT (policy ACCEPT 8 packets, 552 bytes)                         |     Chain OUTPUT (policy ACCEPT 18 packets, 2263 bytes)
 pkts bytes target     prot opt in     out     source               de           pkts bytes target     prot opt in     out     source               de

Chain DOCKER (1 references)                                                     Chain DOCKER (1 references)
 pkts bytes target     prot opt in     out     source               de           pkts bytes target     prot opt in     out     source               de
                                                                          >         0     0 ACCEPT     tcp  --  !docker0 docker0  0.0.0.0/0

Chain DOCKER-ISOLATION-STAGE-1 (1 references)                                   Chain DOCKER-ISOLATION-STAGE-1 (1 references)
 pkts bytes target     prot opt in     out     source               de           pkts bytes target     prot opt in     out     source               de
    0     0 DOCKER-ISOLATION-STAGE-2  all  --  docker0 !docker0  0.0.0              0     0 DOCKER-ISOLATION-STAGE-2  all  --  docker0 !docker0  0.0.0
    0     0 RETURN     all  --  *      *       0.0.0.0/0            0.              0     0 RETURN     all  --  *      *       0.0.0.0/0            0.

Chain DOCKER-ISOLATION-STAGE-2 (1 references)                                   Chain DOCKER-ISOLATION-STAGE-2 (1 references)
 pkts bytes target     prot opt in     out     source               de           pkts bytes target     prot opt in     out     source               de
    0     0 DROP       all  --  *      docker0  0.0.0.0/0            0              0     0 DROP       all  --  *      docker0  0.0.0.0/0            0
    0     0 RETURN     all  --  *      *       0.0.0.0/0            0.              0     0 RETURN     all  --  *      *       0.0.0.0/0            0.

Chain DOCKER-USER (1 references)                                                Chain DOCKER-USER (1 references)
 pkts bytes target     prot opt in     out     source               de           pkts bytes target     prot opt in     out     source               de
    0     0 RETURN     all  --  *      *       0.0.0.0/0            0.              0     0 RETURN     all  --  *      *       0.0.0.0/0            0.
```

```sh
# sdiff iptables_nvL_nat_{before,after}.txt
Chain PREROUTING (policy ACCEPT 0 packets, 0 bytes)                             Chain PREROUTING (policy ACCEPT 0 packets, 0 bytes)
 pkts bytes target     prot opt in     out     source               de           pkts bytes target     prot opt in     out     source               de
    0     0 DOCKER     all  --  *      *       0.0.0.0/0            0.              0     0 DOCKER     all  --  *      *       0.0.0.0/0            0.

Chain INPUT (policy ACCEPT 0 packets, 0 bytes)                                  Chain INPUT (policy ACCEPT 0 packets, 0 bytes)
 pkts bytes target     prot opt in     out     source               de           pkts bytes target     prot opt in     out     source               de

Chain OUTPUT (policy ACCEPT 0 packets, 0 bytes)                           |     Chain OUTPUT (policy ACCEPT 1 packets, 49 bytes)
 pkts bytes target     prot opt in     out     source               de           pkts bytes target     prot opt in     out     source               de
    0     0 DOCKER     all  --  *      *       0.0.0.0/0           !12              0     0 DOCKER     all  --  *      *       0.0.0.0/0           !12

Chain POSTROUTING (policy ACCEPT 0 packets, 0 bytes)                      |     Chain POSTROUTING (policy ACCEPT 1 packets, 49 bytes)
 pkts bytes target     prot opt in     out     source               de           pkts bytes target     prot opt in     out     source               de
    0     0 MASQUERADE  all  --  *      !docker0  172.17.0.0/16                     0     0 MASQUERADE  all  --  *      !docker0  172.17.0.0/16
                                                                          >         0     0 MASQUERADE  tcp  --  *      *       172.17.0.2           1

Chain DOCKER (2 references)                                                     Chain DOCKER (2 references)
 pkts bytes target     prot opt in     out     source               de           pkts bytes target     prot opt in     out     source               de
    0     0 RETURN     all  --  docker0 *       0.0.0.0/0            0              0     0 RETURN     all  --  docker0 *       0.0.0.0/0            0
                                                                          >         0     0 DNAT       tcp  --  !docker0 *       0.0.0.0/0
```

```sh
# sdiff iptables_nvL_mangle_{before,after}.txt
Chain PREROUTING (policy ACCEPT 25 packets, 1585 bytes)                   |     Chain PREROUTING (policy ACCEPT 56 packets, 6067 bytes)
 pkts bytes target     prot opt in     out     source               de           pkts bytes target     prot opt in     out     source               de

Chain INPUT (policy ACCEPT 25 packets, 1585 bytes)                        |     Chain INPUT (policy ACCEPT 56 packets, 6067 bytes)
 pkts bytes target     prot opt in     out     source               de           pkts bytes target     prot opt in     out     source               de

Chain FORWARD (policy ACCEPT 0 packets, 0 bytes)                                Chain FORWARD (policy ACCEPT 0 packets, 0 bytes)
 pkts bytes target     prot opt in     out     source               de           pkts bytes target     prot opt in     out     source               de

Chain OUTPUT (policy ACCEPT 25 packets, 1585 bytes)                       |     Chain OUTPUT (policy ACCEPT 57 packets, 6107 bytes)
 pkts bytes target     prot opt in     out     source               de           pkts bytes target     prot opt in     out     source               de

Chain POSTROUTING (policy ACCEPT 25 packets, 1585 bytes)                  |     Chain POSTROUTING (policy ACCEPT 58 packets, 6156 bytes)
 pkts bytes target     prot opt in     out     source               de           pkts bytes target     prot opt in     out     source               de
```

```sh
# sdiff iptables_nvL_raw_{before,after}.txt
Chain PREROUTING (policy ACCEPT 23 packets, 1466 bytes)                   |     Chain PREROUTING (policy ACCEPT 54 packets, 5948 bytes)
 pkts bytes target     prot opt in     out     source               de           pkts bytes target     prot opt in     out     source               de

Chain OUTPUT (policy ACCEPT 23 packets, 1466 bytes)                       |     Chain OUTPUT (policy ACCEPT 55 packets, 5988 bytes)
 pkts bytes target     prot opt in     out     source               de           pkts bytes target     prot opt in     out     source               de
```


# test4 docker-composeによるコンテナ起動に伴って追加されるルールの確認

初期状態にてdockerサービスを起動したあと、適当なコンテナを起動したのち、さらにdocker-composeでコンテナを起動した。
本試験の意義は、デフォルトのブリッジネットワークdocker0だけではなく、独自のユーザー定義ブリッジネットワークを（docker-composeで）作成した場合の挙動を確認することにある。

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

```sh
# sdiff iptables_nvL_filter_{before,after}.txt
Chain INPUT (policy ACCEPT 7 packets, 1069 bytes)                         |     Chain INPUT (policy ACCEPT 117 packets, 94022 bytes)
 pkts bytes target     prot opt in     out     source               de           pkts bytes target     prot opt in     out     source               de

Chain FORWARD (policy ACCEPT 0 packets, 0 bytes)                                Chain FORWARD (policy ACCEPT 0 packets, 0 bytes)
 pkts bytes target     prot opt in     out     source               de           pkts bytes target     prot opt in     out     source               de
    0     0 DOCKER-USER  all  --  *      *       0.0.0.0/0                          0     0 DOCKER-USER  all  --  *      *       0.0.0.0/0
    0     0 DOCKER-ISOLATION-STAGE-1  all  --  *      *       0.0.0.0/              0     0 DOCKER-ISOLATION-STAGE-1  all  --  *      *       0.0.0.0/
                                                                          >         0     0 ACCEPT     all  --  *      br-09bef16c1f3b  0.0.0.0/0
                                                                          >         0     0 DOCKER     all  --  *      br-09bef16c1f3b  0.0.0.0/0
                                                                          >         0     0 ACCEPT     all  --  br-09bef16c1f3b !br-09bef16c1f3b  0.0.
                                                                          >         0     0 ACCEPT     all  --  br-09bef16c1f3b br-09bef16c1f3b  0.0.0
    0     0 ACCEPT     all  --  *      docker0  0.0.0.0/0            0              0     0 ACCEPT     all  --  *      docker0  0.0.0.0/0            0
    0     0 DOCKER     all  --  *      docker0  0.0.0.0/0            0              0     0 DOCKER     all  --  *      docker0  0.0.0.0/0            0
    0     0 ACCEPT     all  --  docker0 !docker0  0.0.0.0/0                         0     0 ACCEPT     all  --  docker0 !docker0  0.0.0.0/0
    0     0 ACCEPT     all  --  docker0 docker0  0.0.0.0/0                          0     0 ACCEPT     all  --  docker0 docker0  0.0.0.0/0

Chain OUTPUT (policy ACCEPT 8 packets, 1109 bytes)                        |     Chain OUTPUT (policy ACCEPT 121 packets, 90489 bytes)
 pkts bytes target     prot opt in     out     source               de           pkts bytes target     prot opt in     out     source               de

Chain DOCKER (1 references)                                               |     Chain DOCKER (2 references)
 pkts bytes target     prot opt in     out     source               de           pkts bytes target     prot opt in     out     source               de
    0     0 ACCEPT     tcp  --  !docker0 docker0  0.0.0.0/0                         0     0 ACCEPT     tcp  --  !docker0 docker0  0.0.0.0/0
                                                                          >         0     0 ACCEPT     tcp  --  !br-09bef16c1f3b br-09bef16c1f3b  0.0.

Chain DOCKER-ISOLATION-STAGE-1 (1 references)                                   Chain DOCKER-ISOLATION-STAGE-1 (1 references)
 pkts bytes target     prot opt in     out     source               de           pkts bytes target     prot opt in     out     source               de
                                                                          >         0     0 DOCKER-ISOLATION-STAGE-2  all  --  br-09bef16c1f3b !br-09b
    0     0 DOCKER-ISOLATION-STAGE-2  all  --  docker0 !docker0  0.0.0              0     0 DOCKER-ISOLATION-STAGE-2  all  --  docker0 !docker0  0.0.0
    0     0 RETURN     all  --  *      *       0.0.0.0/0            0.              0     0 RETURN     all  --  *      *       0.0.0.0/0            0.

Chain DOCKER-ISOLATION-STAGE-2 (1 references)                             |     Chain DOCKER-ISOLATION-STAGE-2 (2 references)
 pkts bytes target     prot opt in     out     source               de           pkts bytes target     prot opt in     out     source               de
                                                                          >         0     0 DROP       all  --  *      br-09bef16c1f3b  0.0.0.0/0
    0     0 DROP       all  --  *      docker0  0.0.0.0/0            0              0     0 DROP       all  --  *      docker0  0.0.0.0/0            0
    0     0 RETURN     all  --  *      *       0.0.0.0/0            0.              0     0 RETURN     all  --  *      *       0.0.0.0/0            0.

Chain DOCKER-USER (1 references)                                                Chain DOCKER-USER (1 references)
 pkts bytes target     prot opt in     out     source               de           pkts bytes target     prot opt in     out     source               de
    0     0 RETURN     all  --  *      *       0.0.0.0/0            0.              0     0 RETURN     all  --  *      *       0.0.0.0/0            0.
```

```sh
# sdiff iptables_nvL_nat_{before,after}.txt
Chain PREROUTING (policy ACCEPT 0 packets, 0 bytes)                             Chain PREROUTING (policy ACCEPT 0 packets, 0 bytes)
 pkts bytes target     prot opt in     out     source               de           pkts bytes target     prot opt in     out     source               de
    0     0 DOCKER     all  --  *      *       0.0.0.0/0            0.              0     0 DOCKER     all  --  *      *       0.0.0.0/0            0.

Chain INPUT (policy ACCEPT 0 packets, 0 bytes)                                  Chain INPUT (policy ACCEPT 0 packets, 0 bytes)
 pkts bytes target     prot opt in     out     source               de           pkts bytes target     prot opt in     out     source               de

Chain OUTPUT (policy ACCEPT 1 packets, 49 bytes)                          |     Chain OUTPUT (policy ACCEPT 8 packets, 595 bytes)
 pkts bytes target     prot opt in     out     source               de           pkts bytes target     prot opt in     out     source               de
    0     0 DOCKER     all  --  *      *       0.0.0.0/0           !12              0     0 DOCKER     all  --  *      *       0.0.0.0/0           !12

Chain POSTROUTING (policy ACCEPT 1 packets, 49 bytes)                     |     Chain POSTROUTING (policy ACCEPT 8 packets, 595 bytes)
 pkts bytes target     prot opt in     out     source               de           pkts bytes target     prot opt in     out     source               de
                                                                          >         0     0 MASQUERADE  all  --  *      !br-09bef16c1f3b  172.18.0.0/1
    0     0 MASQUERADE  all  --  *      !docker0  172.17.0.0/16                     0     0 MASQUERADE  all  --  *      !docker0  172.17.0.0/16
    0     0 MASQUERADE  tcp  --  *      *       172.17.0.2           1              0     0 MASQUERADE  tcp  --  *      *       172.17.0.2           1
                                                                          >         0     0 MASQUERADE  tcp  --  *      *       172.18.0.2           1

Chain DOCKER (2 references)                                                     Chain DOCKER (2 references)
 pkts bytes target     prot opt in     out     source               de           pkts bytes target     prot opt in     out     source               de
                                                                          >         0     0 RETURN     all  --  br-09bef16c1f3b *       0.0.0.0/0
    0     0 RETURN     all  --  docker0 *       0.0.0.0/0            0              0     0 RETURN     all  --  docker0 *       0.0.0.0/0            0
    0     0 DNAT       tcp  --  !docker0 *       0.0.0.0/0                          0     0 DNAT       tcp  --  !docker0 *       0.0.0.0/0
                                                                          >         0     0 DNAT       tcp  --  !br-09bef16c1f3b *       0.0.0.0/0
```

```sh
# sdiff iptables_nvL_mangle_{before,after}.txt
Chain PREROUTING (policy ACCEPT 115 packets, 37804 bytes)                 |     Chain PREROUTING (policy ACCEPT 385 packets, 214K bytes)
 pkts bytes target     prot opt in     out     source               de           pkts bytes target     prot opt in     out     source               de

Chain INPUT (policy ACCEPT 115 packets, 37804 bytes)                      |     Chain INPUT (policy ACCEPT 385 packets, 214K bytes)
 pkts bytes target     prot opt in     out     source               de           pkts bytes target     prot opt in     out     source               de

Chain FORWARD (policy ACCEPT 0 packets, 0 bytes)                                Chain FORWARD (policy ACCEPT 0 packets, 0 bytes)
 pkts bytes target     prot opt in     out     source               de           pkts bytes target     prot opt in     out     source               de

Chain OUTPUT (policy ACCEPT 115 packets, 31050 bytes)                     |     Chain OUTPUT (policy ACCEPT 391 packets, 203K bytes)
 pkts bytes target     prot opt in     out     source               de           pkts bytes target     prot opt in     out     source               de

Chain POSTROUTING (policy ACCEPT 116 packets, 31099 bytes)                |     Chain POSTROUTING (policy ACCEPT 403 packets, 204K bytes)
 pkts bytes target     prot opt in     out     source               de           pkts bytes target     prot opt in     out     source               de
```

```sh
# sdiff iptables_nvL_raw_{before,after}.txt
Chain PREROUTING (policy ACCEPT 113 packets, 37685 bytes)                 |     Chain PREROUTING (policy ACCEPT 385 packets, 214K bytes)
 pkts bytes target     prot opt in     out     source               de           pkts bytes target     prot opt in     out     source               de

Chain OUTPUT (policy ACCEPT 113 packets, 30931 bytes)                     |     Chain OUTPUT (policy ACCEPT 391 packets, 204K bytes)
 pkts bytes target     prot opt in     out     source               de           pkts bytes target     prot opt in     out     source               de
```
