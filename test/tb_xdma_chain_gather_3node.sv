// Authors:
// - Fanchen Kong <fanchen.kong@kuleuven.be>
//
// ChainGather across three clusters. The data still flows C0 -> C1 -> C2 and the transport
// is bit-for-bit the same as ChainWrite's — but the initiator is the **collector at the
// tail**, C2. It sources none of the payload and is the only node whose core is waiting for
// the answer, so `xdma_finish_o` must land on C2 and, in particular, NOT on C0.
//
// That asymmetry is what the `is_initiator` sideband bit exists for. Before it, completion
// was raised by whichever node carried `is_first_cw`, which conflates "where I sit in the
// data flow" with "whose task this is" — leaving a gather's collector holding the result
// and no completion. This testbench is the mirror of `tb_xdma_chain_write_3node`: same
// stimulus, opposite expected reporter.
//
// The body is shared with `tb_xdma_chain_write_3node`; see `xdma_chain_3node_body.sv`.

`timescale 1ns / 1ps

module tb_xdma_chain_gather_3node ();

  xdma_chain_3node_body #(
      .Gather(1'b1)
  ) i_body ();

endmodule
