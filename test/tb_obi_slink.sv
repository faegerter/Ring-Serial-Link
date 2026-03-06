// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//

module tb_obi_slink;

    import slink_reg_pkg::*;
    import obi_pkg::*;

    `include "obi/typedef.svh"
    `include "obi/assign.svh"

  `include "slink_addrmap.svh"

    // ==============
    //    Config
    // ==============
    localparam int unsigned TestDuration    = 100;
    localparam int unsigned MaxClkDiv       = 2**Log2MaxClkDiv;

    localparam time         TckSys1         = 50ns;
    localparam time         TckSys2         = 54ns;
    localparam time         TckReg          = 200ns;
    localparam int unsigned RstClkCyclesSys = 1;

    localparam int unsigned ObiIdWidth      = 1;
    localparam int unsigned ObiAddrWidth    = 32;
    localparam int unsigned ObiDataWidth    = 32;

    localparam int unsigned RegAddrWidth    = 32;
    localparam int unsigned RegDataWidth    = 32;
    localparam int unsigned RegStrbWidth    = RegDataWidth / 8;

    // ==============
    //    DDR Link
    // ==============

    // OBI configuration and types
    localparam obi_cfg_t ObiCfg = obi_default_cfg(ObiAddrWidth, ObiDataWidth, ObiIdWidth, ObiMinimalOptionalConfig);

    `OBI_TYPEDEF_DEFAULT_ALL(obi, ObiCfg)

  typedef logic [NumLanes*(1+EnDdr)-1:0]  phy_data_t;

    // Model signals
    logic [NumChannels-1:0]  ddr_rcv_clk_1, ddr_rcv_clk_2;

    obi_req_t   obi_out_req_1, obi_out_req_2;
    obi_rsp_t   obi_out_rsp_1, obi_out_rsp_2;
    obi_req_t   obi_in_req_1,  obi_in_req_2;
    obi_rsp_t   obi_in_rsp_1,  obi_in_rsp_2;

  // link
  wire [NumChannels*NumLanes-1:0] ddr_o;
  wire [NumChannels*NumLanes-1:0] ddr_i;

    // clock and reset
    logic clk_1, clk_2, clk_reg;
    logic rst_1_n, rst_2_n, rst_reg_n;

    // system clock and reset
    clk_rst_gen #(
        .ClkPeriod    ( TckReg          ),
        .RstClkCycles ( RstClkCyclesSys )
    ) i_clk_rst_gen_reg (
        .clk_o  ( clk_reg   ),
        .rst_no ( rst_reg_n )
    );

    clk_rst_gen #(
        .ClkPeriod    ( TckSys1         ),
        .RstClkCycles ( RstClkCyclesSys )
    ) i_clk_rst_gen_sys_1 (
        .clk_o  ( clk_1   ),
        .rst_no ( rst_1_n )
    );

    clk_rst_gen #(
        .ClkPeriod    ( TckSys2          ),
        .RstClkCycles ( RstClkCyclesSys  )
    ) i_clk_rst_gen_sys_2 (
        .clk_o  ( clk_2   ),
        .rst_no ( rst_2_n )
    );

  // first serial instance
  slink #(
    .obi_req_t       ( obi_req_t       ),
    .obi_rsp_t       ( obi_rsp_t       ),
    .a_chan_t        ( obi_a_chan_t    ),
    .r_chan_t        ( obi_r_chan_t    )
  ) i_serial_link_1 (
      .clk_i         ( clk_1           ),
      .rst_ni        ( rst_1_n         ),
      .clk_sl_i      ( clk_1           ),
      .rst_sl_ni     ( rst_1_n         ),
      .clk_reg_i     ( clk_reg         ),
      .rst_reg_ni    ( rst_reg_n       ),
      .testmode_i    ( 1'b0            ),
      .obi_in_req_i  ( obi_in_req_1    ),
      .obi_in_rsp_o  ( obi_in_rsp_1    ),
      .obi_out_req_o ( obi_out_req_1   ),
      .obi_out_rsp_i ( obi_out_rsp_1   ),
      .ddr_rcv_clk_i ( ddr_rcv_clk_2   ),
      .ddr_rcv_clk_o ( ddr_rcv_clk_1   ),
      .ddr_i         ( ddr_i           ),
      .ddr_o         ( ddr_o           )
  );

  // second serial instance
  slink #(
    .obi_req_t       ( obi_req_t       ),
    .obi_rsp_t       ( obi_rsp_t       ),
    .a_chan_t        ( obi_a_chan_t    ),
    .r_chan_t        ( obi_r_chan_t    )
  ) i_serial_link_2 (
      .clk_i         ( clk_2           ),
      .rst_ni        ( rst_2_n         ),
      .clk_sl_i      ( clk_2           ),
      .rst_sl_ni     ( rst_2_n         ),
      .clk_reg_i     ( clk_reg         ),
      .rst_reg_ni    ( rst_reg_n       ),
      .testmode_i    ( 1'b0            ),
      .obi_in_req_i  ( obi_in_req_2    ),
      .obi_in_rsp_o  ( obi_in_rsp_2    ),
      .obi_out_req_o ( obi_out_req_2   ),
      .obi_out_rsp_i ( obi_out_rsp_2   ),
      .ddr_rcv_clk_i ( ddr_rcv_clk_1   ),
      .ddr_rcv_clk_o ( ddr_rcv_clk_2   ),
      .ddr_i         ( ddr_o           ),
      .ddr_o         ( ddr_i           )
  );

  // OBI DV interfaces
  OBI_BUS_DV #(
    .OBI_CFG        ( ObiCfg          ),
    .obi_a_optional_t ( obi_a_optional_t ),
    .obi_r_optional_t ( obi_r_optional_t )
  ) obi_in_1  (clk_1, rst_1_n),
    obi_out_1 (clk_1, rst_1_n);

    OBI_BUS_DV #(
        .OBI_CFG        ( ObiCfg          ),
        .obi_a_optional_t ( obi_a_optional_t ),
        .obi_r_optional_t ( obi_r_optional_t )
    ) obi_in_2  (clk_2, rst_2_n),
        obi_out_2 (clk_2, rst_2_n);


    assign obi_out_1.err = 1'b0;
    assign obi_out_2.err = 1'b0;

    // Connect struct-level OBI signals to DV interfaces (manager side)
    // SoC manager drives `obi_in_*` interfaces, which are converted into
    // struct-level requests for the `slink` subordinate.
    // A channel: interface -> struct
    assign obi_in_req_1.a.addr       = obi_in_1.addr;
    assign obi_in_req_1.a.we         = obi_in_1.we;
    assign obi_in_req_1.a.be         = obi_in_1.be;
    assign obi_in_req_1.a.wdata      = obi_in_1.wdata;
    assign obi_in_req_1.a.aid        = obi_in_1.aid;
    assign obi_in_req_1.a.a_optional = obi_in_1.a_optional;
    assign obi_in_req_1.req          = obi_in_1.req;

    assign obi_in_req_2.a.addr       = obi_in_2.addr;
    assign obi_in_req_2.a.we         = obi_in_2.we;
    assign obi_in_req_2.a.be         = obi_in_2.be;
    assign obi_in_req_2.a.wdata      = obi_in_2.wdata;
    assign obi_in_req_2.a.aid        = obi_in_2.aid;
    assign obi_in_req_2.a.a_optional = obi_in_2.a_optional;
    assign obi_in_req_2.req          = obi_in_2.req;

    // R channel and grant: struct -> interface
    assign obi_in_1.gnt        = obi_in_rsp_1.gnt;
    assign obi_in_1.rvalid     = obi_in_rsp_1.rvalid;
    assign obi_in_1.rdata      = obi_in_rsp_1.r.rdata;
    assign obi_in_1.rid        = obi_in_rsp_1.r.rid;
    assign obi_in_1.err        = obi_in_rsp_1.r.err;
    assign obi_in_1.r_optional = obi_in_rsp_1.r.r_optional;

    assign obi_in_2.gnt        = obi_in_rsp_2.gnt;
    assign obi_in_2.rvalid     = obi_in_rsp_2.rvalid;
    assign obi_in_2.rdata      = obi_in_rsp_2.r.rdata;
    assign obi_in_2.rid        = obi_in_rsp_2.r.rid;
    assign obi_in_2.err        = obi_in_rsp_2.r.err;
    assign obi_in_2.r_optional = obi_in_rsp_2.r.r_optional;

    // Connect struct-level OBI signals to DV interfaces (subordinate side)
    // `slink` acts as OBI manager on the `obi_out_*` side, DV environment
    // provides random subordinate behavior.
    // A channel: struct -> interface
    assign obi_out_1.addr       = obi_out_req_1.a.addr;
    assign obi_out_1.we         = obi_out_req_1.a.we;
    assign obi_out_1.be         = obi_out_req_1.a.be;
    assign obi_out_1.wdata      = obi_out_req_1.a.wdata;
    assign obi_out_1.aid        = obi_out_req_1.a.aid;
    assign obi_out_1.a_optional = obi_out_req_1.a.a_optional;
    assign obi_out_1.req        = obi_out_req_1.req;

    assign obi_out_2.addr       = obi_out_req_2.a.addr;
    assign obi_out_2.we         = obi_out_req_2.a.we;
    assign obi_out_2.be         = obi_out_req_2.a.be;
    assign obi_out_2.wdata      = obi_out_req_2.a.wdata;
    assign obi_out_2.aid        = obi_out_req_2.a.aid;
    assign obi_out_2.a_optional = obi_out_req_2.a.a_optional;
    assign obi_out_2.req        = obi_out_req_2.req;

    // R channel and grant: interface -> struct
    assign obi_out_rsp_1.gnt           = obi_out_1.gnt;
    assign obi_out_rsp_1.rvalid        = obi_out_1.rvalid;
    assign obi_out_rsp_1.r.rdata       = obi_out_1.rdata;
    assign obi_out_rsp_1.r.rid         = obi_out_1.rid;
    assign obi_out_rsp_1.r.err         = obi_out_1.err;
    assign obi_out_rsp_1.r.r_optional  = obi_out_1.r_optional;

    assign obi_out_rsp_2.gnt           = obi_out_2.gnt;
    assign obi_out_rsp_2.rvalid        = obi_out_2.rvalid;
    assign obi_out_rsp_2.r.rdata       = obi_out_2.rdata;
    assign obi_out_rsp_2.r.rid         = obi_out_2.rid;
    assign obi_out_rsp_2.r.err         = obi_out_2.err;
    assign obi_out_rsp_2.r.r_optional  = obi_out_2.r_optional;
    

    // ==============
    //    OBI DV
    // ==============

    typedef obi_test::obi_driver #(
        .ObiCfg           ( ObiCfg           ),
        .obi_a_optional_t ( obi_a_optional_t ),
        .obi_r_optional_t ( obi_r_optional_t ),
        .TA               ( 100ps            ),
        .TT               ( 500ps            )
    ) obi_driver_t;

    // Local copy of the upstream random manager with safe data randomization for 32-bit data.
    class obi_rand_manager_fixed;
        typedef logic [ObiCfg.AddrWidth-1:0] addr_t;

        string name;
        obi_driver_t drv;
        addr_t a_queue[$];

        function new(
            virtual OBI_BUS_DV #(
                .OBI_CFG          ( ObiCfg           ),
                .obi_a_optional_t ( obi_a_optional_t ),
                .obi_r_optional_t ( obi_r_optional_t )
            ) obi,
            input string name
        );
            this.drv = new(obi);
            this.name = name;
        endfunction

        function void reset();
            drv.reset_manager();
        endfunction

        task automatic rand_wait(input int unsigned min, input int unsigned max);
            int unsigned rand_success, cycles;
            rand_success = std::randomize(cycles) with {
                cycles >= min;
                cycles <= max;
            };
            assert (rand_success) else $error("Failed to randomize wait cycles!");
            repeat (cycles) @(posedge this.drv.obi.clk_i);
        endtask

        task automatic send_as(input int unsigned n_reqs);
            automatic addr_t a_addr;
            automatic logic a_we;
            automatic logic [ObiCfg.DataWidth/8-1:0] a_be;
            automatic logic [ObiCfg.DataWidth-1:0] a_wdata;
            automatic logic [ObiCfg.IdWidth-1:0] a_aid;
            automatic obi_a_optional_t a_optional;

            repeat (n_reqs) begin
                rand_wait(0, 100);

                a_addr = $urandom();
                a_we = $urandom() % 2;
                assert(std::randomize(a_be));
                // Avoid the upstream `% (1 << DataWidth)` bug at 32-bit widths.
                assert(std::randomize(a_wdata));
                assert(std::randomize(a_aid));
                assert(std::randomize(a_optional));

                this.a_queue.push_back(a_addr);
                this.drv.send_a(a_addr, a_we, a_be, a_wdata, a_aid, a_optional);
            end
        endtask

        task automatic recv_rs(input int unsigned n_rsps);
            automatic addr_t a_addr;
            automatic logic [ObiCfg.DataWidth-1:0] r_rdata;
            automatic logic [ObiCfg.IdWidth-1:0] r_rid;
            automatic logic r_err;
            automatic obi_r_optional_t r_optional;

            repeat (n_rsps) begin
                wait (a_queue.size() > 0);
                a_addr = this.a_queue.pop_front();
                rand_wait(0, 100);
                drv.recv_r(r_rdata, r_rid, r_err, r_optional);
            end
        endtask

        task automatic run(int unsigned n_reqs);
            fork
                this.send_as(n_reqs);
                this.recv_rs(n_reqs);
            join
        endtask
    endclass

    typedef obi_test::obi_rand_subordinate #(
        .ObiCfg         ( ObiCfg            ),
        .obi_a_optional_t ( obi_a_optional_t ),
        .obi_r_optional_t ( obi_r_optional_t ),
        .TA             ( 100ps             ),
        .TT             ( 500ps             ),
        .AMinWaitCycles ( 0                 ),
        .AMaxWaitCycles ( 100               ),
        .RMinWaitCycles ( 0                 ),
        .RMaxWaitCycles ( 100               )
    ) obi_rand_subordinate_t;

    static obi_rand_manager_fixed obi_rand_manager_1 = new ( obi_in_1,  "obi_mst_1" );
    static obi_rand_manager_fixed obi_rand_manager_2 = new ( obi_in_2,  "obi_mst_2" );

    static obi_rand_subordinate_t obi_rand_subordinate_1 = new ( obi_out_1, "obi_slv_1" );
    static obi_rand_subordinate_t obi_rand_subordinate_2 = new ( obi_out_2, "obi_slv_2" );

    logic [1:0] mst_done;

    // By default perform TestDuration transactions per side
    int NumReqs_1 = TestDuration;
    int NumReqs_2 = TestDuration;

    initial begin
    end

    // Subordinates
    initial begin
        obi_rand_subordinate_1.reset();
        wait_for_reset_1();
        obi_rand_subordinate_1.run();
    end

    initial begin
        obi_rand_subordinate_2.reset();
        wait_for_reset_2();
        obi_rand_subordinate_2.run();
    end

    // Manager on side 1 with bandwidth measurement
    initial begin
        automatic time start_cycle, end_cycle;
        automatic int unsigned data_sent = 0;
        automatic int unsigned data_received = 0;
        if ($value$plusargs("NUM_REQS_1=%d", NumReqs_1)) begin
            $info("[OBI1] Number of requests specified as %d", NumReqs_1);
        end
        mst_done[0] = 0;
        obi_rand_manager_1.reset();
        wait_for_reset_1();
        start_cycle = $realtime;
        fork
            obi_rand_manager_1.run(NumReqs_1);
            forever begin
                @(posedge clk_1);
                if (obi_in_req_1.req & obi_in_rsp_1.gnt) begin
                    data_sent += $bits(obi_in_req_1);
                end
                if (obi_in_rsp_1.rvalid) begin
                    data_received += $bits(obi_in_rsp_1);
                end
            end
        join_any
        end_cycle = $realtime;
        $info("OBI BW %0d/%0d (sent/rcv) Mbit/s @ %0d/%0d MHz (SoC/PHY)",
            data_sent * 1000 / (end_cycle - start_cycle),
            data_received * 1000 / (end_cycle - start_cycle),
            1000 / TckSys1,
            1000 / TckSys1 / 8);
        mst_done[0] = 1;
    end

    // Manager on side 2
    initial begin
        if ($value$plusargs("NUM_REQS_2=%d", NumReqs_2)) begin
            $info("[OBI2] Number of requests specified as %d", NumReqs_2);
        end
        mst_done[1] = 0;
        obi_rand_manager_2.reset();
        wait_for_reset_2();
        obi_rand_manager_2.run(NumReqs_2);
        mst_done[1] = 1;
    end

  // ==============
  //    Tasks
  // ==============

    task automatic wait_for_reset_1();
        @(posedge rst_1_n);
    endtask

    task automatic wait_for_reset_2();
        @(posedge rst_2_n);
    endtask

    task automatic stop_sim();
        repeat(50) begin
            @(posedge clk_1);
        end
        $display("[SYS] Simulation Stopped (%d ns)", $time);
        $stop();
    endtask

endmodule : tb_obi_slink

