# xdma-axi-adapter

The xdma-axi-adapter is the interface between the xdma and the axi ports. The XDMA frontend
speaks in cross-cluster payloads — a cfg frame, a data stream, and two sideband descriptors —
and this adapter turns them into AXI write bursts on two buses, and turns arriving bursts back
into those payloads.

Only the AW and W channels are used. Nothing here issues a read: a "remote read" is a write of
a cfg frame that asks the far side to write the data back.

## Two buses, four channels

| Channel | Bus | Direction | Carries |
|---|---|---|---|
| `cfg` | narrow | out and in | the 512-bit cross-cluster cfg frame, serialised to 8 × 64 bit |
| `data` | wide | out and in | the payload, 512 bit per beat |
| `grant` | narrow | out and in | one beat: "I am ready to receive your data" |
| `finish` | narrow | out and in | one beat: "your data has landed" |

cfg, grant and finish all share the narrow bus, so a stall on any one of them stalls the other
two. Several of the design's less obvious rules exist to keep that from happening — see
[Invariants](#invariants).

## Address map

Each cluster owns `ClusterAddressSpace` bytes, and the top `MMIOSize` KiB of it is four equally
sized windows. A transfer is addressed by writing into the window of the *receiving* cluster;
the address selects the channel, and the payload is what matters, not the offset within the
window.

```
cluster end addr ─┬─ finish   (cluster_end - 1 * MMIOSize/4 KiB)
                  ├─ grant    (cluster_end - 2 * MMIOSize/4 KiB)
                  ├─ cfg      (cluster_end - 3 * MMIOSize/4 KiB)
                  └─ data     (cluster_end - 4 * MMIOSize/4 KiB)
```

With the defaults (`MMIOSize = 16`) each window is 4 KiB, which is also the AXI 4 KiB burst
boundary — so a burst starting at a window base never crosses out of it.

A destination address above `MainMemBaseAddr` resolves against main memory instead of a
cluster, and the top `ChipIdWidth` bits of an address name the chip, which is what makes a
transfer cross a die boundary.

## How a remote write completes

```
        wide data
  C0 ───────────────► C1
   │                   │
   └── cfg (narrow) ───┤     C0 tells C1 what is coming
       grant ◄─────────┤     C1 says it is ready; C0 may now send data
       finish ◄────────┘     C1 says it has landed; C0 raises xdma_finish_o
```

1. **cfg.** `to_remote_cfg_i` presents one 512-bit frame per `frame_length`. `dw_converter`
   serialises it to 8 narrow beats, and `xdma_burst_reshaper` turns the descriptor into an AXI
   burst into C1's cfg window. A multi-frame cfg holds the sender in `sSendFrameBody` until the
   last frame is consumed, because the descriptor is decoded combinationally from whatever sits
   on `to_remote_cfg_i`.
2. **grant.** C1's `xdma_grant_manager` sees its accompany cfg go ready and sends one beat back
   into C0's grant window. C0 buffers it; `grant` gates the wide data AW.
3. **data.** C0 streams beats into C1's data window on the wide bus. `xdma_burst_reshaper` splits
   anything longer than one page into successive bursts.
4. **finish.** When C1's window closes, its `xdma_finish_manager` sends one beat into C0's finish
   window, and C0 pulses `xdma_finish_o` for one cycle. The frontend counts those cycles, so two
   completions in consecutive cycles read as two.

For a chained write the same steps run hop by hop: the head carries `is_first_cw`, the tail
carries `is_last_cw`, intermediate nodes carry neither, and grants and finishes cascade
backwards along the chain.

## Modules

| Module | Role |
|---|---|
| `xdma_axi_adapter_top` | wiring, address decode, descriptor composition, all typedefs |
| `xdma_req_manager` | arbitrates the inputs sharing one bus; one transfer at a time |
| `xdma_burst_reshaper` | descriptor → AW/W descriptors, splitting at the page size |
| `xdma_req_backend` | AW/W FIFOs and the AXI master side |
| `xdma_data_path` | drives the W channel and counts beats to `w_last` |
| `xdma_meta_manager` | counts accepted beats and raises `done` |
| `xdma_grant_manager` | decides when to grant an incoming write, and to whom |
| `xdma_finish_manager` | three FSMs: read, first write, middle/last write |
| `xdma_axi_to_write` | AXI slave → a simple write request stream |
| `xdma_write_demux` | routes an arriving narrow write to cfg, grant or finish by address |
| `dw_converter` | `dw_up_converter` / `dw_down_converter` / passthrough by width |
| `find_first_one_idx` | priority encoder, MSB first (cfg > grant > finish) |

## Invariants

These are the rules that are easy to break and expensive to debug. Each is stated at its site
in the RTL; they are collected here because most of them are cross-module.

- **A VALID offered to `xdma_req_manager` may not retract.** It commits to an input on VALID
  alone and leaves BUSY only on a beat count, so a VALID that disappears strands it, and the
  whole bus with it. Sources driven by a live external level must latch their decision first.
- **A descriptor is read combinationally at push time, not at arbitration time.** Anything
  feeding one must hold still for the whole transaction, or freeze a copy.
- **Nothing on a shared bus may refuse a beat indefinitely.** The receive path has no error
  sink, so an unroutable or unexpected beat is accepted and buffered rather than stalled — a
  stalled beat takes down every channel on that bus.
- **AWSIZE must match the instance's strobe width**, and a data-forward AW must not be issued
  before its W data exists.
- **`dma_length` of 0 is not serviceable** and is asserted against.

## Simulation

```bash
source <your MICAS EDA env>   # QuestaSim
make all                      # compile + run every testbench in $(TBS)
make sim_gui TB=xdma_axi_adapter_top
```

`scripts/compile_vsim.sh` passes the `xdma_axi_adapter_test` bender target, which is what pulls
this repo's own testbenches into the compile.

| Testbench | Covers |
|---|---|
| `tb_find_first_one_idx` | narrow-channel priority encoder |
| `tb_xdma_grant_hold` | grant VALID stability, and recovery from an illegal FSM state |
| `tb_xdma_write_demux_error` | an unmapped address is retired, a mapped one still back-pressures |
| `tb_xdma_zero_length_guard` | burst splitting at 1 / 64 / >page beats, and the zero-length bound |
| `tb_xdma_finish_backpressure` | the narrow port takes a finish nobody is waiting for; the sticky write-readiness latch |
| `tb_xdma_axi_adapter_top` | 2 clusters, a plain remote write, wide **and** narrow bus |

`tb_xdma_axi_adapter_top` wires the narrow bus as well as the wide one. cfg, grant and finish
all ride the narrow bus, so without it no transfer can complete.

`test/tb_xdma_meta_manager.sv` and `test/tb_xdma_burst_reshaper.sv` are unit testbenches that
are not in `$(TBS)`; run them by name with `make sim-xdma_meta_manager.log`.

# Author
Fanchen Kong (fanchen.kong@kuleuven.be)

Yunhao Deng (yunhao.deng@kuleuven.be)
