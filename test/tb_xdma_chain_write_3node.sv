// Authors:
// - Fanchen Kong <fanchen.kong@kuleuven.be>
//
// ChainWrite across three clusters: C0 sources the payload, C1 forwards it, C2 sinks it.
// The initiator is the head — the node that owns the task is also the node that sourced
// the data — so `xdma_finish_o` must land on C0 and nowhere else.
//
// The body is shared with `tb_xdma_chain_gather_3node`; see `xdma_chain_3node_body.sv`.

`timescale 1ns / 1ps

module tb_xdma_chain_write_3node ();

  xdma_chain_3node_body #(
      .Gather(1'b0)
  ) i_body ();

endmodule
