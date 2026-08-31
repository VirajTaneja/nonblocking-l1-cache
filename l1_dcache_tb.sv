`timescale 1ns/1ps

module l1_dcache_tb;

    localparam int ADDR_W = 32;
    localparam int DATA_W = 32;
    localparam int ID_W = 4;
    localparam int SETS = 64;
    localparam int LINE_BYTES = 64;
    localparam int MSHRS = 2;
    localparam int LINE_W = LINE_BYTES * 8;

    logic clk;
    logic rst_n;

    logic cpu_req_valid;
    logic cpu_req_ready;
    logic [ID_W-1:0] cpu_req_id;
    logic [ADDR_W-1:0] cpu_req_addr;
    logic cpu_req_write;
    logic [DATA_W-1:0] cpu_req_wdata;
    logic [(DATA_W/8)-1:0] cpu_req_wstrb;

    logic cpu_resp_valid;
    logic cpu_resp_ready;
    logic [ID_W-1:0] cpu_resp_id;
    logic [DATA_W-1:0] cpu_resp_rdata;

    logic mem_req_valid;
    logic mem_req_ready;
    logic mem_req_write;
    logic [ADDR_W-1:0] mem_req_addr;
    logic [LINE_W-1:0] mem_req_wdata;
    logic mem_req_mshr_id;

    logic mem_resp_valid;
    logic mem_resp_ready;
    logic mem_resp_mshr_id;
    logic [LINE_W-1:0] mem_resp_rdata;

    logic [31:0] perf_accesses;
    logic [31:0] perf_hits;
    logic [31:0] perf_misses;
    logic [31:0] perf_writebacks;
    logic [31:0] perf_mshr_stall_cycles;
    logic [31:0] perf_set_conflict_stalls;

    integer cycle_count;
    integer resp_cycle [0:15];
    logic [31:0] resp_data [0:15];

    l1_dcache #(
        .ADDR_W(ADDR_W),
        .DATA_W(DATA_W),
        .ID_W(ID_W),
        .SETS(SETS),
        .LINE_BYTES(LINE_BYTES),
        .MSHRS(MSHRS),
        .ALLOW_HIT_UNDER_MISS(1'b1)
    ) dut (
        .*
    );

    memory_model #(
        .ADDR_W(ADDR_W),
        .DATA_W(DATA_W),
        .LINE_BYTES(LINE_BYTES),
        .MSHRS(MSHRS),
        .MEM_LINES(1024),
        .READ_LATENCY(12)
    ) u_mem (
        .clk(clk),
        .rst_n(rst_n),

        .mem_req_valid(mem_req_valid),
        .mem_req_ready(mem_req_ready),
        .mem_req_write(mem_req_write),
        .mem_req_addr(mem_req_addr),
        .mem_req_wdata(mem_req_wdata),
        .mem_req_mshr_id(mem_req_mshr_id),

        .mem_resp_valid(mem_resp_valid),
        .mem_resp_ready(mem_resp_ready),
        .mem_resp_mshr_id(mem_resp_mshr_id),
        .mem_resp_rdata(mem_resp_rdata)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    initial cycle_count = 0;
    always @(posedge clk) begin
        if (rst_n)
            cycle_count = cycle_count + 1;

        if (rst_n && cpu_resp_valid && cpu_resp_ready) begin
            resp_cycle[cpu_resp_id] = cycle_count;
            resp_data[cpu_resp_id] = cpu_resp_rdata;
            $display("[%0t] RESP id=%0d data=0x%08x",
                     $time, cpu_resp_id, cpu_resp_rdata);
        end
    end

    task automatic clear_resp(input integer id);
        begin
            resp_cycle[id] = -1;
            resp_data[id] = 'x;
        end
    endtask

    task automatic issue_req(
        input logic [ID_W-1:0] id,
        input logic [ADDR_W-1:0] addr,
        input logic is_write,
        input logic [DATA_W-1:0] wdata,
        input logic [(DATA_W/8)-1:0] wstrb
    );
        bit accepted;
        begin
            accepted = 0;
            @(negedge clk);
            cpu_req_valid = 1'b1;
            cpu_req_id    = id;
            cpu_req_addr  = addr;
            cpu_req_write = is_write;
            cpu_req_wdata = wdata;
            cpu_req_wstrb = wstrb;

            while (!accepted) begin
                @(posedge clk);
                if (cpu_req_ready)
                    accepted = 1;
            end

            @(negedge clk);
            cpu_req_valid = 1'b0;
        end
    endtask

    task automatic wait_resp(
        input integer id,
        input logic [31:0] expected
    );
        integer timeout;
        begin
            timeout = 0;
            while ((resp_cycle[id] < 0) && (timeout < 300)) begin
                @(negedge clk);
                timeout = timeout + 1;
            end

            if (resp_cycle[id] < 0)
                $fatal(1, "Timeout waiting for response id=%0d", id);

            if (resp_data[id] !== expected)
                $fatal(1,
                    "Bad response id=%0d expected=0x%08x got=0x%08x",
                    id, expected, resp_data[id]);
        end
    endtask

    task automatic do_read(
        input integer id,
        input logic [31:0] addr,
        input logic [31:0] expected
    );
        begin
            clear_resp(id);
            issue_req(id[ID_W-1:0], addr, 1'b0, '0, '0);
            wait_resp(id, expected);
        end
    endtask

    task automatic do_write(
        input integer id,
        input logic [31:0] addr,
        input logic [31:0] data,
        input logic [3:0] strb
    );
        begin
            clear_resp(id);
            issue_req(id[ID_W-1:0], addr, 1'b1, data, strb);
            wait_resp(id, 32'h00000000);
        end
    endtask

    initial begin : test_sequence
        integer k;
        integer stall_observed;
        bit accepted;
        logic [31:0] A;
        logic [31:0] D0, D1, D2;
        logic [31:0] HIT_ADDR, MISS_ADDR;
        logic [31:0] T0, T1, T2;

        cpu_req_valid = 1'b0;
        cpu_req_id    = '0;
        cpu_req_addr  = '0;
        cpu_req_write = 1'b0;
        cpu_req_wdata = '0;
        cpu_req_wstrb = '0;
        cpu_resp_ready = 1'b1;
        rst_n = 1'b0;

        for (k = 0; k < 16; k = k + 1) begin
            resp_cycle[k] = -1;
            resp_data[k] = 'x;
        end

        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        $display("\n=== TEST 1: cold read miss then read hit ===");
        A = 32'h0000_0140;
        do_read(0, A, A);
        do_read(1, A, A);

        $display("\n=== TEST 2: write hit and byte enables ===");
        do_write(2, A, 32'hAABB_CCDD, 4'b1111);
        do_read (3, A, 32'hAABB_CCDD);
        do_write(4, A, 32'h1122_3344, 4'b0011);
        do_read (5, A, 32'hAABB_3344);

        $display("\n=== TEST 3: dirty eviction/writeback + LRU ===");
        // These three line-aligned addresses map to the same set and different tags.
        D0 = 32'h0000_0200;
        D1 = 32'h0000_1200;
        D2 = 32'h0000_2200;

        do_read (6, D0, D0);
        do_read (7, D1, D1);
        do_write(8, D0, 32'hDEAD_BEEF, 4'b1111); // D0 dirty and MRU
        do_read (9, D1, D1);                     // D1 MRU => D0 becomes LRU
        do_read (10, D2, D2);                    // Must evict/write back D0

        if (u_mem.mem[D0 >> 6][31:0] !== 32'hDEAD_BEEF)
            $fatal(1, "Dirty victim was not written back correctly.");

        $display("\n=== TEST 4: hit-under-miss ===");
        HIT_ADDR  = 32'h0000_0440; // set 17
        MISS_ADDR = 32'h0000_3480; // different set; initially absent

        do_read(11, HIT_ADDR, HIT_ADDR); // preload line so it will hit

        clear_resp(12);
        clear_resp(13);

        issue_req(4'd12, MISS_ADDR, 1'b0, '0, '0);
        issue_req(4'd13, HIT_ADDR,  1'b0, '0, '0);

        wait_resp(13, HIT_ADDR);
        wait_resp(12, MISS_ADDR);

        if (!(resp_cycle[13] < resp_cycle[12]))
            $fatal(1,
                "Expected independent hit to complete before outstanding miss.");

        $display("Hit-under-miss confirmed: hit cycle=%0d, miss cycle=%0d",
                 resp_cycle[13], resp_cycle[12]);

        $display("\n=== TEST 5: two MSHRs + third-miss backpressure ===");
        T0 = 32'h0000_5000;
        T1 = 32'h0000_5040;
        T2 = 32'h0000_5080;

        clear_resp(0);
        clear_resp(1);
        clear_resp(2);

        issue_req(4'd0, T0, 1'b0, '0, '0);
        issue_req(4'd1, T1, 1'b0, '0, '0);

        // Hold a third miss until one MSHR becomes available.
        stall_observed = 0;
        accepted = 0;
        @(negedge clk);
        cpu_req_valid = 1'b1;
        cpu_req_id    = 4'd2;
        cpu_req_addr  = T2;
        cpu_req_write = 1'b0;
        cpu_req_wdata = '0;
        cpu_req_wstrb = '0;

        while (!accepted) begin
            @(posedge clk);
            if (cpu_req_ready)
                accepted = 1;
            else
                stall_observed = stall_observed + 1;
        end

        @(negedge clk);
        cpu_req_valid = 1'b0;

        if (stall_observed == 0)
            $fatal(1, "Expected third miss to stall while both MSHRs were occupied.");

        wait_resp(0, T0);
        wait_resp(1, T1);
        wait_resp(2, T2);

        $display("Third miss stalled for %0d cycle(s) as expected.",
                 stall_observed);

        $display("\n=== PERFORMANCE COUNTERS ===");
        $display("accesses             = %0d", perf_accesses);
        $display("hits                 = %0d", perf_hits);
        $display("misses               = %0d", perf_misses);
        $display("writebacks           = %0d", perf_writebacks);
        $display("MSHR stall cycles    = %0d", perf_mshr_stall_cycles);
        $display("set-conflict stalls  = %0d", perf_set_conflict_stalls);

        $display("\n============================================");
        $display("ALL DIRECTED TESTS PASSED");
        $display("============================================\n");

        repeat (5) @(posedge clk);
        $finish;
    end

endmodule
