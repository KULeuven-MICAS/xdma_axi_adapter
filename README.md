# xdma-axi-adapter
The xdma-axi-adapter is the interface between the xdma and the axi ports.

## Simulation

```bash
source <your MICAS EDA env>   # QuestaSim
make all                      # compile + run every testbench in $(TBS)
make sim_gui TB=xdma_chain_3node
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
| `tb_xdma_chain_3node` | 3 clusters: a chained transfer, including the middle hop |

Both multi-cluster testbenches wire the **narrow** AXI bus as well as the wide one. cfg,
grant and finish all ride the narrow bus, so without it no transfer can complete.

## Chained transfers (ChainWrite / ChainGather)

The adapter needs no changes to carry a linear, leaf-initiated ChainGather: the wide data
path is payload-agnostic and all control decode comes from the accompany-cfg sideband,
whose encodings are identical to ChainWrite's — head = `is_first_cw`, middles = neither,
tail = `is_last_cw`. `tb_xdma_chain_3node` exercises that path end to end.

Two diagnostics are available for bring-up, both **off by default** so they cost nothing
unless asked for:

* **`StallTimeout`** (`xdma_axi_adapter_top`) — every wait in the adapter's control path is
  unbounded, so a wedged chain hop hangs silently. Set this to the number of consecutive
  cycles a control FSM may sit in a wait state without advancing; a trip latches the new
  sticky output **`xdma_stall_error_o`** and prints which FSM in which instance gave up.
  Pick a few times the worst-case transfer length. `0` removes the logic entirely.
* **`SpuriousFinishGuard`** (`xdma_axi_adapter_top`) — backstop against a ChainGather
  middle node being mistaken for the chain head and raising a spurious `xdma_finish_o`.
  The primary fix belongs in Chisel; see the parameter's comment in
  `src/xdma_finish_manager.sv` for when enabling it here is the wrong call.

# Author
Fanchen Kong (fanchen.kong@kuleuven.be)

Yunhao Deng (yunhao.deng@kuleuven.be)
