// Authors:
// - Fanchen Kong <fanchen.kong@kuleuven.be>
//
// Two ChainGathers at once through the two clusters of every chip, with the whole-burst remote
// writes on: both must complete, at several offsets between the chains. See
// `xdma_concurrent_chains_body`.

module tb_xdma_concurrent_chains;
  xdma_concurrent_chains_body #(
      .WholeBurst    (1'b1),
      .ExpectDeadlock(1'b0)
  ) i_body ();
endmodule
