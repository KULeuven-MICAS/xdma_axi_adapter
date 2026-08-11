// Authors:
// - Fanchen Kong <fanchen.kong@kuleuven.be>
// - Yunhao Deng <yunhao.deng@kuleuven.be>
module find_first_one_idx #(
    parameter int unsigned N = 4,
    /// Dependent parameters, DO NOT OVERRIDE!
    parameter integer LOG_N_INP = $clog2(N)
) (
    input  logic [        N-1:0] in_i,
    output logic [LOG_N_INP-1:0] idx_o,
    output logic                 valid_o
);
  if (N==32'd1) begin : gen_direct
    // if the input is only 1
    // make direct connection
    assign valid_o = in_i;
    assign idx_o = '0;
  end else begin : gen_find_idx
    // else the input is more than 1
    // generate the find_idx circuit 
    logic found;
    always_comb begin : find_idx
      idx_o   = '0;
      valid_o = |in_i;
      found   = 1'b0;
      for (int i = 0; i < N; i++) begin
        // Search from MSB to LSB: the scan runs over indices N-1 down to 0, so the first
        // match is the highest set bit and every index stays inside the vector. The xdma
        // narrow inputs are (cfg, grant, finish), and cfg must win.
        if (!found && in_i[N-1-i]) begin
          idx_o = LOG_N_INP'(N-1-i);
          found = 1'b1;
        end
      end
    end    
  end

endmodule
