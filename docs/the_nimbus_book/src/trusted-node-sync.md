# Trusted node sync

When you start the beacon node for the first time, it will connect to the beacon chain network and start syncing automatically, a process that can take several days.

Trusted node sync allows you to get started more quickly with Nimbus by fetching a recent checkpoint from a trusted node.

To use trusted node sync, you must have access to a node that you trust that exposes the REST HTTP API, for example a locally running backup node.

Should this node or your connection to it be compromised, your node will not be able to detect that it's being served false information.

It is possibly to use trusted node sync with a third-party API provider - follow the steps below to verify that the chain you were given corresponds to the canonical chain at the time.

## Performing a trusted node sync

**Prater (testnet)**

```bash
build/nimbus_beacon_node trustedNodeSync --network:prater \
 --data-dir=build/data/shared_prater_0  \
 --trusted-node-url=http://localhost:5052
```

**Mainnet**

```bash
build/nimbus_beacon_node trustedNodeSync --network:mainnet \
 --data-dir=build/data/shared_mainnet_0 \
 --trusted-node-url=http://localhost:5052
```

**NOTE**

Because trusted node sync by default copies all blocks via REST, if you use a third-party service to sync from, you may hit API limits - see the `--backfill` option.

## Verifying that you synced the correct chain

When performing a trusted node sync, you can manually verify that the correct chain was synced by comparing the head hash with other sources, such as friends, forums, chats and web sites. You can retrieve the current head from the node using:

```
# Make sure to enabled the `--rest` option when running your node:

curl http://localhost:5052/eth/v1/beacon/blocks/head/root
```

The `head` root is also printed in the log output at regular intervals.

## Block history

By default, both the state and the full block history will be downloaded from the trusted node.

It is possible to get started more quickly by delaying the backfill of the block history using the `--backfill=false` parameter. In this case, the beacon node will first sync to the current head so that it can start performing its duties, then backfill the blocks from the network.

While it's backfilling blocks from the network, the node will be violating the beacon chain protocol and may be disconnected or lose reputation with other nodes.

## Sync point

By default, the node will sync up to the latest finalized checkpoint of the node that you're syncing with. You can choose a different sync point using a block hash or a slot number - this block must fall on an epoch boundary:

```
build/nimbus_beacon_node trustedNodeSync --blockId:0x239940f2537f5bbee1a3829f9058f4c04f49897e4d325145153ca89838dfc9e2 ...

```

## Sync from checkpoint files

If you have a state and a block file available, you can instead start the node using the finalized checkpoint options:

```
# Obtain a state and a block from a REST API - these must be in SSZ format:

curl -o state.32000.ssz -H 'Accept: application/octet-stream' http://localhost:5052/eth/v2/debug/beacon/states/32000
curl -o block.32000.ssz -H 'Accept: application/octet-stream' http://localhost:5052/eth/v2/beacon/blocks/32000

build/nimbus_beacon_node --data-dir:trusted --finalized-checkpoint-block=block.32000.ssz --finalized-checkpoint-state=state.32000.ssz
```

## Caveats

A node synced using trusted node sync will not be able to serve historical requests via the REST API from before the checkpoint. Future versions will resolve this issue.