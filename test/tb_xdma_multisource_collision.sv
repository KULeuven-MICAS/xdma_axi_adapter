// Authors:
// - Fanchen Kong <fanchen.kong@kuleuven.be>
//
// Reproducer for the single-remote-context deadlock.
//
// Two sources write to one destination and their receive windows ABUT: the destination's
// `ready_to_transfer` never falls between them, because its local writer is still busy
// taking delivery of the second write. See `xdma_multisource_2to1_body` for the full
// mechanism.
//
// If a context retires on the bare level, this wedges all three nodes and a stall watchdog
// reports it.
module tb_xdma_multisource_collision ();
  xdma_multisource_2to1_body #(.SerialiseWindows(1'b0)) i_body ();
endmodule
