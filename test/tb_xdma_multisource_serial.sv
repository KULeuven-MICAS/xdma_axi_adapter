// Authors:
// - Fanchen Kong <fanchen.kong@kuleuven.be>
//
// Control arm for `tb_xdma_multisource_collision`: two sources write to one destination,
// but the destination's receive window closes completely -- and the first write retires --
// before the second is named. One remote context is enough for that. It exists to prove that
// the collision arm's failure comes from the abutting windows and from nothing else in the
// setup.
//
// It is the "receiver otherwise idle" case: two issuers that happen not to overlap.
module tb_xdma_multisource_serial ();
  xdma_multisource_2to1_body #(.SerialiseWindows(1'b1)) i_body ();
endmodule
