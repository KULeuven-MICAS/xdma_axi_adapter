# xdma-axi-adapter
The xdma-axi-adapter is the interface between the xdma and the axi ports.

## Simulation

```bash
source <your MICAS EDA env>   # QuestaSim
make all                      # compile + run every testbench in $(TBS)
make sim_gui TB=xdma_chain_gather_3node
```

`scripts/compile_vsim.sh` passes the `xdma_axi_adapter_test` bender target, which is what
pulls this repo's own testbenches into the compile. Testbenches:

| Testbench | Covers |
|---|---|
| `tb_find_first_one_idx` | narrow-channel priority encoder |
| `tb_xdma_meta_manager` / `tb_xdma_burst_reshaper` | unit level |
| `tb_xdma_stall_watchdog` | the bring-up stall watchdog |
| `tb_xdma_finish_manager_guard` | the `SpuriousFinishGuard` backstop, on and off |
| `tb_xdma_axi_adapter_top` | 2 clusters: a plain remote write, wide **and** narrow bus |
| `tb_xdma_chain_write_3node` | 3 clusters, ChainWrite: initiator at the head |
| `tb_xdma_chain_gather_3node` | 3 clusters, ChainGather: initiator at the tail |
| `tb_xdma_multisource_serial` | 3 clusters, two sources -> one destination, windows disjoint |
| `tb_xdma_multisource_collision` | the same, with the two receive windows abutting |
| `tb_xdma_multisource_read_collision` | the same, with a local remote read already in flight |
| `tb_xdma_mutual_exchange_2node` | 2 clusters writing to each other at once, sender window held |
| `tb_xdma_mutual_exchange_2node_drop` | the same, sender window dropped once the data is out |
| `tb_xdma_finish_manager_completion_merge` | `xdma_finish_o` must report one cycle per retired task |

The two chain testbenches share `test/xdma_chain_3node_body.sv` and differ only in one
parameter — which is the point: the transport is identical and only task ownership moves.
The three `multisource` testbenches share `test/xdma_multisource_2to1_body.sv` the same way;
see [Concurrent remote transfers](#concurrent-remote-transfers-into-one-node) below.

Both multi-cluster testbenches wire the **narrow** AXI bus as well as the wide one. cfg,
grant and finish all ride the narrow bus, so without it no transfer can complete.

## Chained transfers (ChainWrite / ChainGather)

**The data plane is identical in both modes.** The wide path is payload-agnostic and every
control decode comes from the accompany-cfg sideband, whose position encodings are the same
either way — head = `is_first_cw`, middles = neither, tail = `is_last_cw`.

**The completion path is not**, and that is what `is_initiator` exists for. Position in the
data flow says who must *forward* a finish; it does not say whose task it is. The two
coincide for ChainWrite and are opposite for ChainGather, whose initiator is the collector
at the tail — the node that sources none of the data and is the only one waiting for the
answer.

### Example: a 3-node chain

Three clusters, `ClusterBaseAddr = 0x1000_0000`, `ClusterAddressSpace = 0x0010_0000`,
`MMIOSize = 16` — so `C0 = 0x1000_0000`, `C1 = 0x1010_0000`, `C2 = 0x1020_0000`.

Roles are assigned by **position in the data flow**, not by cluster number: whoever sources
the stream is the head, whoever terminates it is the tail. Data flows C0 → C1 → C2 below.

**Task ownership is a separate axis**, carried by `is_initiator`:

|  | initiator | cfg walks | `xdma_finish_o` lands on |
|---|---|---|---|
| **ChainWrite** | the head | C0 → C2 | C0 — which also sourced the data |
| **ChainGather** | the tail | C2 → C0 | C2 — the collector, which sourced nothing |

`is_initiator` means *"this node issued the task, so raise `xdma_finish_o` on my core when
the chain retires"*. Set it on the initiator's own sideband — the `to_remote` copy at a head,
the `from_remote` copy at a tail — and clear it everywhere else. For ChainWrite it equals
`is_first_cw`, so every pre-existing transfer is bit-compatible.

Only `xdma_finish_manager` reads it, and it gates the *output*, not the FSM: a non-initiator
head still runs its finish FSM to completion, because that is what releases its grant credit.
The backwards finish cascade is byte-identical in both modes; only the node allowed to pulse
its core changes.

```
        wide data          wide data
  C0 ───────────────► C1 ───────────────► C2
 head                middle               tail
  ◄─────────────── grant ◄─────────────── grant        (narrow, backwards)
  ◄────────────── finish ◄────────────── finish        (narrow, backwards)
```

**The sideband each node's XDMA must present.** Every column but the last is the *same* for
ChainWrite and ChainGather:

| node | port | `dma_type` | `src_addr` | `dst_addr` | `dma_length` | `is_first_cw` | `is_last_cw` | `is_initiator` |
|---|---|---|---|---|---|---|---|---|
| 0 head | `to_remote_data_accompany_cfg` | 1 | C0 | C1 | L | **1** | 0 | write: **1** / gather: 0 |
| 1 middle | `from_remote_data_accompany_cfg` | 1 | C0 | C1 | L | 0 | 0 | 0 |
| 1 middle | `to_remote_data_accompany_cfg` | 1 | C1 | C2 | L | 0 | 0 | 0 |
| 2 tail | `from_remote_data_accompany_cfg` | 1 | C1 | C2 | L | 0 | **1** | write: 0 / gather: **1** |

`ready_to_transfer` is a **level**, not a pulse: each node holds it for its whole
participation window. The tail dropping its `ready_to_transfer` is what releases the finish
cascade. The head's and the tail's unused ports are all-zero. `src_addr` is what the grant
and finish are routed back along, so it must name the *previous* hop.

**What differs between the two modes** — only what sits between the two wide ports of the
middle node, which is Chisel, not this repo:

| | middle node forwards | middle node's local memory | busy level it must assert |
|---|---|---|---|
| **ChainWrite** | the incoming stream unchanged | receives a copy of the stream | writer busy |
| **ChainGather** | incoming stream joined element-wise with data read from its own TCDM | untouched | reader / junction busy |


The head reads its local TCDM and sources the stream; the tail writes what it receives into
its local TCDM. Both are the same in either mode.

An element-wise join keeps `dma_length` constant along the chain, which is why the same L
appears at every hop above. The adapter never sees the local read or the join: it only sees
bytes arriving on `from_remote_data` and bytes leaving on `to_remote_data`, and it never
compares the two. The chain testbenches model the junction with a plain FIFO for exactly
this reason — from the adapter's side a FIFO and a reducer are indistinguishable.

Note the busy level differs, and that is where both known ChainGather hazards live: a
gather middle that stops writing locally must still produce a busy level for its whole
participation window, or `ready_to_transfer` never reaches the grant manager and the chain
deadlocks; and its concurrently-running reader must not make its `to_remote` sideband
momentarily read as a chain head (see `SpuriousFinishGuard` below).

**What actually crosses the wire.** Addresses are derived from the peer's cluster end
address minus a per-channel MMIO offset (data −16 KiB, cfg −12 KiB, grant −8 KiB,
finish −4 KiB):

| order | bus | from → to | target address | derived from |
|---|---|---|---|---|
| 1 | narrow | C0 → C1 | `0x101F_D000` | cfg, from `writer_addr` |
| 2 | narrow | C1 → C2 | `0x102F_D000` | cfg, from `writer_addr` |
| 3 | narrow | C2 → C1 | `0x101F_E000` | grant, from the tail's `src_addr` |
| 4 | narrow | C1 → C0 | `0x100F_E000` | grant, from the middle's `src_addr` |
| 5 | wide | C0 → C1 | `0x101F_C000` | data, from the head's `dst_addr` |
| 6 | wide | C1 → C2 | `0x102F_C000` | data, from the middle's `dst_addr` |
| 7 | narrow | C2 → C1 | `0x101F_F000` | finish, from the tail's `src_addr` |
| 8 | narrow | C1 → C0 | `0x100F_F000` | finish, from the middle's `src_addr` |

The grant cascade (3, 4) necessarily precedes the data (5, 6): a node's wide `aw_valid` and
`w_valid` are gated on its grant credit, so the head cannot start until the credit has
walked all the way back from the tail. Rows 1 and 2 reverse for ChainGather, where the
initiator configures the chain outward from the tail; the other six are unchanged.

Exactly one node raises `xdma_finish_o` — the initiator — and both chain testbenches assert
that the other two stay silent. See `run_chain()` in `test/xdma_chain_3node_body.sv` for the
whole sequence as executable code.

## Concurrent remote transfers into one node

A chain is linear: every node is a hop in exactly one transaction at a time, which is the
assumption `xdma_grant_manager`'s `WRITE_MIDDLE` / `SEND_GRANT_TO_PREV_HOP` states were
written under. A node that is the destination of two *unrelated* remote transfers breaks it,
and that is the star-multicast and multi-issuer-broadcast case.

The receiving node has one `from_remote_data_accompany_cfg` port, so two receive windows
necessarily arrive one after the other on it. `ready_to_transfer` is a level derived from the
node's own busy state, and three FSMs used to take that bare level as "my transfer ended":

| FSM | old exit | what it means when a second transfer abuts |
|---|---|---|
| `xdma_grant_manager` `WAIT_FINISH` | `grant_valid == 0` | never returns to `IDLE`, so the second sender is never granted |
| `xdma_finish_manager` `WriteLastBusy` | `~ready_to_transfer` | the first transfer's finish is never cascaded back, so its sender waits forever |
| `xdma_finish_manager` `ReadBusy` | `~ready_to_transfer` | a write landing behind a local read wedges the read's completion |

Each now compares the live port against the `(dma_id, src_addr)` it latched when it armed,
so "the window closed" means *the port stopped naming my transfer* rather than *the node went
idle*. Both fields are needed: `dma_id` is only unique per source.

**Scope.** A sending side that drops the level between transfers never presents a changed
identity while the level is high, and against it these predicates are equivalent to the levels
they replace. They make each FSM's exit condition local rather than dependent on that property,
which is what a fabric-replicated multicast would require.

The three `multisource` testbenches differ in one parameter each and isolate the effect:

* **`serial`** — the destination fully closes window A, and A retires, before B is named.
  One context is enough for that, so this passed before the change too. It is the control:
  it proves the other two arms fail because of the abutting windows and nothing else.
* **`collision`** — B opens on the cycle A stops being named. Before the change this wedged
  all three nodes: the destination in `WAIT_FINISH` + `WriteLastBusy`, both senders in
  `WriteFirstBusy`, 8 of 16 beats delivered.
* **`read_collision`** — the destination is already taking delivery of a remote read of its
  own when the writes arrive. Before the change this tripped
  `i_xdma_finish_manager.i_read_stall_watchdog` on the receiver.

Two further defects live in the same area and were found alongside it. Both are independent of
the above and were reproduced on the real frontend.

**`xdma_finish_o` could not be counted.** It is one bit shared by three completion sources and
carries no id, so the frontend can only tell two completions apart by counting assertions. It
was driven from FSM1's and FSM2's *held valid levels*, and the arbitration below them gives
FSM3's single-cycle pulse priority — so a held-but-not-yet-accepted completion kept the output
high for a second cycle. One task retiring and two tasks retiring produced the identical
waveform, and no counting rule can be right about both. It is now pinned to the **accepted
handshakes**, exactly as `xdma_write_finish_o` beside it already was.

**A node that both sends and receives.** `SpuriousFinishGuard` retracts a head claim on
`dma_type & ready_to_transfer & ~is_first_cw`. That predicate uses chain POSITION, and position
cannot tell a spurious claim from a genuine outgoing write on a node that also receives — both
present the same bits. So a node receiving any remote write had its head claim retracted,
including the claim on its own unrelated outgoing transfer, and could not re-arm: the to-remote
window is only ~3 cycles, so once retracted there is nothing left to arm on. Its own task then
never completed, with **nothing stalling and no watchdog firing**.

The retract now also passes when the node OWNS the outgoing task. Two forms, because the two
uses sample at different times — the same live-versus-latched split `to_remote_dma_id_q` exists
for. Arming is evaluated with `head_claim`, so the live `is_initiator` describes the claim;
retracting fires from `WriteFirstBusy` with no `head_claim` term, long after the window closed,
so it uses `to_remote_is_initiator_q`.

`tb_xdma_mutual_exchange_2node_drop` covers it.

**What this does not do.** Contexts are still singular, so a context retires on its own
schedule while the next one arms behind it. At today's transfer lengths the margin is ample
(the second sender's grant round trip is far longer than the first's finish send), but it is
a margin, not a guarantee. Replicating the contexts per source — one armed while another
retires — is what turns it into one; the adapter needs that only once the Chisel frontend can
present genuinely overlapping receive windows, which with a single accompany-cfg port it
cannot today.

### Bring-up diagnostics

Two diagnostics are available, both **off by default** so they cost nothing unless asked
for:

* **`StallTimeout`** (`xdma_axi_adapter_top`) — every wait in the adapter's control path is
  unbounded, so a wedged chain hop hangs silently. Set this to the number of consecutive
  cycles a control FSM may sit in a wait state without advancing; a trip latches the new
  sticky output **`xdma_stall_error_o`** and prints which FSM in which instance gave up.
  Pick a few times the worst-case transfer length. `0` removes the logic entirely.
* **`SpuriousFinishGuard`** (`xdma_axi_adapter_top`) — backstop against a ChainGather
  middle node being mistaken for the chain head. `is_initiator` already blocks the
  core-visible symptom (a middle never owns the task), but not the latch itself: a
  mis-triggered head FSM also releases a grant credit nothing reserved. That is what this
  guard prevents, and what `tb_xdma_finish_manager_guard` measures. The primary fix belongs
  in Chisel; see the parameter's comment in `src/xdma_finish_manager.sv` for when enabling
  it here is the wrong call.

# Author
Fanchen Kong (fanchen.kong@kuleuven.be)

Yunhao Deng (yunhao.deng@kuleuven.be)
