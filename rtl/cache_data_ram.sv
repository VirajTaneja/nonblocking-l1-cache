`timescale 1ns/1ps

// 1K x 32 true-dual-port RAM with byte write enables.
// For the default cache geometry:
//   64 sets * 16 words/line = 1024 words per way.
// Each instance stores one cache way (4 KiB).
//
// The storage is intentionally not reset. Cache validity is controlled by
// valid bits in l1_dcache, so stale RAM contents are never architecturally
// visible after reset.
//
// This coding style is intended to infer FPGA block RAM in Vivado.
module cache_data_ram #(
    parameter int DEPTH  = 1024,
    parameter int DATA_W = 32
) (
    input  logic                     clk,

    // Port A: CPU hit path
    input  logic [$clog2(DEPTH)-1:0] a_addr,
    output logic [DATA_W-1:0]        a_rdata,
    input  logic [(DATA_W/8)-1:0]    a_we,
    input  logic [DATA_W-1:0]        a_wdata,

    // Port B: refill / writeback maintenance path
    input  logic [$clog2(DEPTH)-1:0] b_addr,
    output logic [DATA_W-1:0]        b_rdata,
    input  logic [(DATA_W/8)-1:0]    b_we,
    input  logic [DATA_W-1:0]        b_wdata
);

    localparam int BYTE_LANES = DATA_W / 8;

    (* ram_style = "block" *)
    logic [DATA_W-1:0] mem [0:DEPTH-1];

    integer i;
    always_ff @(posedge clk) begin
        // Synchronous read on port A.
        a_rdata <= mem[a_addr];

        // Byte-enabled write on port A.
        for (i = 0; i < BYTE_LANES; i = i + 1) begin
            if (a_we[i])
                mem[a_addr][i*8 +: 8] <= a_wdata[i*8 +: 8];
        end
    end

    integer j;
    always_ff @(posedge clk) begin
        // Synchronous read on port B.
        b_rdata <= mem[b_addr];

        // Byte-enabled write on port B.
        for (j = 0; j < BYTE_LANES; j = j + 1) begin
            if (b_we[j])
                mem[b_addr][j*8 +: 8] <= b_wdata[j*8 +: 8];
        end
    end

endmodule
