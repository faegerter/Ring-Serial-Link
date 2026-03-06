// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//

module tb_obi_slink;

  import slink_reg_pkg::*;
  import obi_pkg::*;

  `include "obi/typedef.svh"
  `include "obi/assign.svh"

  `include "apb/assign.svh"
  `include "apb/typedef.svh"

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

  localparam int unsigned ObiIdWidth      = 3;
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

  // APB types for typedefs
  typedef logic [RegAddrWidth-1:0]  cfg_addr_t;
  typedef logic [RegDataWidth-1:0]  cfg_data_t;
  typedef logic [RegStrbWidth-1:0]  cfg_strb_t;

  `APB_TYPEDEF_ALL(apb, cfg_addr_t, cfg_data_t, cfg_strb_t)

  typedef logic [NumLanes*(1+EnDdr)-1:0]  phy_data_t;

  // Model signals
  logic [NumChannels-1:0]  ddr_rcv_clk_1, ddr_rcv_clk_2;

  obi_req_t   obi_out_req_1, obi_out_req_2;
  obi_rsp_t   obi_out_rsp_1, obi_out_rsp_2;
  obi_req_t   obi_in_req_1,  obi_in_req_2;
  obi_rsp_t   obi_in_rsp_1,  obi_in_rsp_2;

  apb_req_t   apb_req_1;
  apb_resp_t  apb_rsp_1;
  apb_req_t   apb_req_2;
  apb_resp_t  apb_rsp_2;

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
    .obi_req_t       ( obi_req_t  ),
    .obi_rsp_t       ( obi_rsp_t  ),
    .a_chan_t        ( obi_a_chan_t ),
    .r_chan_t        ( obi_r_chan_t ),
    .apb_req_t       ( apb_req_t  ),
    .apb_rsp_t       ( apb_resp_t )
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
      .apb_req_i     ( apb_req_1       ),
      .apb_rsp_o     ( apb_rsp_1       ),
      .ddr_rcv_clk_i ( ddr_rcv_clk_2   ),
      .ddr_rcv_clk_o ( ddr_rcv_clk_1   ),
      .ddr_i         ( ddr_i           ),
      .ddr_o         ( ddr_o           )
  );

  // second serial instance
  slink #(
    .obi_req_t       ( obi_req_t  ),
    .obi_rsp_t       ( obi_rsp_t  ),
    .a_chan_t        ( obi_a_chan_t ),
    .r_chan_t        ( obi_r_chan_t ),
    .apb_req_t       ( apb_req_t  ),
    .apb_rsp_t       ( apb_resp_t )
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
      .apb_req_i     ( apb_req_2       ),
      .apb_rsp_o     ( apb_rsp_2       ),
      .ddr_rcv_clk_i ( ddr_rcv_clk_1   ),
      .ddr_rcv_clk_o ( ddr_rcv_clk_2   ),
      .ddr_i         ( ddr_o           ),
      .ddr_o         ( ddr_i           )
  );

  // APB DV interfaces
  APB_DV #(
    .ADDR_WIDTH (RegAddrWidth),
    .DATA_WIDTH (RegDataWidth)
  ) cfg_1(clk_reg), cfg_2(clk_reg);

  `APB_ASSIGN_TO_REQ(apb_req_1, cfg_1)
  `APB_ASSIGN_FROM_RESP(cfg_1, apb_rsp_1)

  `APB_ASSIGN_TO_REQ(apb_req_2, cfg_2)
  `APB_ASSIGN_FROM_RESP(cfg_2, apb_rsp_2)

  typedef apb_test::apb_driver #(
    .ADDR_WIDTH ( RegAddrWidth  ),
    .DATA_WIDTH ( RegDataWidth  ),
    .TA ( 100ps         ),
    .TT ( 500ps         )
  ) apb_master_t;

  static apb_master_t apb_master_1 = new ( cfg_1 );
  static apb_master_t apb_master_2 = new ( cfg_2 );

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

  typedef obi_test::obi_rand_manager #(
    .ObiCfg         ( ObiCfg            ),
    .obi_a_optional_t ( obi_a_optional_t ),
    .obi_r_optional_t ( obi_r_optional_t ),
    .TA             ( 100ps             ),
    .TT             ( 500ps             ),
    .MinAddr        ( 32'h0000_0000     ),
    .MaxAddr        ( 32'hFFFF_FFFF     ),
    .AMinWaitCycles ( 0                 ),
    .AMaxWaitCycles ( 100               ),
    .RMinWaitCycles ( 0                 ),
    .RMaxWaitCycles ( 100               )
  ) obi_rand_manager_t;

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

  static obi_rand_manager_t     obi_rand_manager_1 = new ( obi_in_1,  "obi_mst_1" );
  static obi_rand_manager_t     obi_rand_manager_2 = new ( obi_in_2,  "obi_mst_2" );

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

  // Stimuli process (APB config and end-of-test)
  initial begin : stimuli_process
    apb_master_1.reset_master();
    apb_master_2.reset_master();
    fork
      wait_for_reset_1();
      wait_for_reset_2();
    join
    $info("[SYS] Reset complete");
    fork
      start_link(apb_master_1, 1);
      start_link(apb_master_2, 2);
    join
    $info("[SYS] Links are ready");
    while (mst_done != '1) begin
      @(posedge clk_1);
    end
    stop_sim();
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

  task automatic cfg_write(apb_master_t drv, cfg_addr_t addr, cfg_data_t data, cfg_strb_t strb='1);
    automatic logic resp;
    drv.write(addr, data, strb, resp);
    assert (!resp) else $error("Not able to write cfg reg");
  endtask

  task automatic cfg_read(apb_master_t drv, cfg_addr_t addr, output cfg_data_t data);
    automatic logic resp;
    drv.read(addr, data, resp);
    assert (!resp) else $error("Not able to write cfg reg");
  endtask

  task automatic start_link(apb_master_t drv, int id);
    // automatic phy_data_t pattern, pattern_q[$];
    // automatic cfg_data_t data;
    // $info("[LINK%0d]: Enabling clock and deassert link reset.", id);
    // // Reset and clock gate sequence, isolation remains enabled
    // // De-assert reset
    // cfg_write(drv, `SLINK_REG_CTRL_REG_OFFSET, 32'h300);
    // // Assert reset
    // cfg_write(drv, `SLINK_REG_CTRL_REG_OFFSET, 32'h302);
    // // Enable clock
    // cfg_write(drv, `SLINK_REG_CTRL_REG_OFFSET, 32'h303);
    // // Wait for some clock cycles
    // repeat(50) drv.cycle_end();
    // // De-isolate ports
    // $info("[LINK%0d] Enabling ports...",id);
    // cfg_write(drv, `SLINK_REG_CTRL_REG_OFFSET, 32'h03);
    // do begin
    //   cfg_read(drv, `SLINK_REG_ISOLATED_REG_OFFSET, data);
    // end while(data != 0); // Wait until both isolation status bits are 0 to
    //                       // indicate disabling of isolation
    // $info("[LINK%0d] Link is ready", id);
  endtask;

endmodule : tb_obi_slink

