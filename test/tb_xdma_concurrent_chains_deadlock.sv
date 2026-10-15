// Authors:
// - Fanchen Kong <fanchen.kong@kuleuven.be>
//
// The same two concurrent ChainGathers with the whole-burst remote writes off: the run must
// deadlock. It passes when it does, so a change that stops `xdma_concurrent_chains_body` from
// reaching the hazard fails here instead of silently passing `tb_xdma_concurrent_chains`.

module tb_xdma_concurrent_chains_deadlock;
  xdma_concurrent_chains_body #(
      .WholeBurst    (1'b0),
      .ExpectDeadlock(1'b1)
  ) i_body ();
endmodule
