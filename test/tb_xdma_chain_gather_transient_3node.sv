// Authors:
// - Fanchen Kong <fanchen.kong@kuleuven.be>
//
// `tb_xdma_chain_gather_3node` with the middle hop's local-reader transient replayed, so the
// full adapter -- not just `xdma_finish_manager` in isolation -- runs two consecutive gathers
// through a node that momentarily presents a head-shaped to-remote cfg.
//
// Without the head-claim guard the middle's FSM2 latches on that transient and releases a
// grant credit nothing reserved; latch it with a stale id and the node is finished for the
// run. See `tb_xdma_finish_manager_gather_rearm` for the mechanism, decomposed.

`timescale 1ns / 1ps

module tb_xdma_chain_gather_transient_3node ();
  xdma_chain_3node_body #(
      .Gather         (1'b1),
      .ReaderTransient(1'b1)
  ) i_body ();
endmodule
