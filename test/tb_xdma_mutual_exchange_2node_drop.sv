// Authors:
// - Fanchen Kong <fanchen.kong@kuleuven.be>
//
// Same exchange, but each node drops its to-remote window as soon as it has pushed its last
// beat, instead of holding it until its own completion arrives. A sending side whose window
// tracks its reader behaves this way: the reader is done once the data is out, long before the
// finish walks back. `tb_xdma_axi_adapter_top` sequences a plain remote write the same way.
//
// For a pure sender that is harmless: FSM2 armed when the window opened and nothing
// retracts it. For a node that is ALSO receiving, `SpuriousFinishGuard` retracts the claim
// -- and with `head_claim` gone there is nothing left to re-arm on.
module tb_xdma_mutual_exchange_2node_drop ();
  xdma_mutual_exchange_2node_body #(.HoldSenderWindow(1'b0)) i_body ();
endmodule
