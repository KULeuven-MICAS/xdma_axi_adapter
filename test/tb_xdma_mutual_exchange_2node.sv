// Authors:
// - Fanchen Kong <fanchen.kong@kuleuven.be>
//
// Mutual exchange with each node's to-remote window held open until its own completion
// arrives. See `xdma_mutual_exchange_2node_body` for what this probes.

module tb_xdma_mutual_exchange_2node ();
  xdma_mutual_exchange_2node_body #(.HoldSenderWindow(1'b1)) i_body ();
endmodule
