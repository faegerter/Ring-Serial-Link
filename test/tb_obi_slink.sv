// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//

`define OBI_CONNECT_MANAGER(_if, _req, _rsp) \
    /* A channel: interface -> struct */ \
    assign _req.a.addr       = _if.addr; \
    assign _req.a.we         = _if.we; \
    assign _req.a.be         = _if.be; \
    assign _req.a.wdata      = _if.wdata; \
    assign _req.a.aid        = _if.aid; \
    assign _req.a.a_optional = _if.a_optional; \
    assign _req.req          = _if.req; \
    /* R channel + grant: struct -> interface */ \
    assign _if.gnt           = _rsp.gnt; \
    assign _if.rvalid        = _rsp.rvalid; \
    assign _if.rdata         = _rsp.r.rdata; \
    assign _if.rid           = _rsp.r.rid; \
    assign _if.err           = _rsp.r.err; \
    assign _if.r_optional    = _rsp.r.r_optional;


`define OBI_CONNECT_SUBORDINATE(_if, _req, _rsp) \
    /* A channel: struct -> interface */ \
    assign _if.addr          = _req.a.addr; \
    assign _if.we            = _req.a.we; \
    assign _if.be            = _req.a.be; \
    assign _if.wdata         = _req.a.wdata; \
    assign _if.aid           = _req.a.aid; \
    assign _if.a_optional    = _req.a.a_optional; \
    assign _if.req           = _req.req; \
    /* R channel + grant: interface -> struct */ \
    assign _rsp.gnt          = _if.gnt; \
    assign _rsp.rvalid       = _if.rvalid; \
    assign _rsp.r.rdata      = _if.rdata; \
    assign _rsp.r.rid        = _if.rid; \
    assign _rsp.r.err        = _if.err; \
    assign _rsp.r.r_optional = _if.r_optional;



module tb_obi_slink;

    import slink_reg_pkg::*;
    import slink_pkg::*;
    import obi_pkg::*;
    import obi_test_fix_pkg::*;

    `include "obi/typedef.svh"
    `include "obi/assign.svh"

    `include "slink_addrmap.svh"
    `include "../include/slink_obi/typedef.svh"

    // ==============
    //    Config
    // ==============
    localparam int unsigned TestDuration    = 10;
    localparam int unsigned MaxClkDiv       = 2**Log2MaxClkDiv;

    localparam time         TckSys1         = 50ns;
    localparam time         TckSys2         = 54ns;
    localparam int unsigned RstClkCyclesSys = 1;

    localparam int unsigned ObiIdWidth      = 1;
    localparam int unsigned ObiAddrWidth    = 32;
    localparam int unsigned ObiDataWidth    = 32;

    localparam int unsigned RegAddrWidth    = 32;
    localparam int unsigned RegDataWidth    = 32;
    localparam int unsigned RegStrbWidth    = RegDataWidth / 8;

    localparam bit          UseByteEnable   = 1;
    localparam bit          UseOptional     = 0;

    // ==============
    //    DDR Links
    // ==============

    // OBI configuration and types
    localparam obi_cfg_t ObiCfg = obi_default_cfg(ObiAddrWidth, ObiDataWidth, ObiIdWidth, ObiMinimalOptionalConfig);
    localparam slink_obi_cfg_t SlinkObiCfg = slink_obi_cfg(ObiAddrWidth, ObiDataWidth, ObiDataWidth, ObiIdWidth, UseByteEnable, UseOptional);

    `OBI_TYPEDEF_DEFAULT_ALL(obi, ObiCfg)
    `SLINK_OBI_TYPEDEF_DEFAULT(slink_obi, SlinkObiCfg) 

    typedef logic [ObiIdWidth-1:0]    obi_id_t;
    typedef logic [RegAddrWidth-1:0]  cfg_addr_t;
    typedef logic [RegDataWidth-1:0]  cfg_data_t;

    // Model signals
    logic [NumChannels-1:0]  ddr_rcv_clk_1, ddr_rcv_clk_2;

    obi_req_t   obi_out_req_1, obi_out_req_2;
    obi_rsp_t   obi_out_rsp_1, obi_out_rsp_2;
    obi_req_t   obi_in_req_1,  obi_in_req_2;
    obi_rsp_t   obi_in_rsp_1,  obi_in_rsp_2;
    obi_req_t   obi_reg_req_1,  obi_reg_req_2;
    obi_rsp_t   obi_reg_rsp_1,  obi_reg_rsp_2;

    // link
    wire [NumChannels*NumLanes-1:0] ddr_o;
    wire [NumChannels*NumLanes-1:0] ddr_i;
    wire credit_recv_clk_i, credit_rtrn_clk_o;

    // clock and reset
    logic clk_1, clk_2;
    logic rst_1_n, rst_2_n;

    // system clock and reset
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
        .obi_req_t       ( obi_req_t        ),
        .obi_rsp_t       ( obi_rsp_t        ),
        .a_optional_t   ( obi_a_optional_t  ),
        .r_optional_t   ( obi_r_optional_t  ),
        // .a_chan_t        ( obi_a_chan_t     ),
        // .r_chan_t        ( obi_r_chan_t     ),
        .a_chan_write_t  ( slink_obi_a_chan_write_t   ),
        .a_chan_read_t   ( slink_obi_a_chan_read_t    ),
        .r_chan_write_t  ( slink_obi_r_chan_write_t   ),
        .r_chan_read_t   ( slink_obi_r_chan_read_t    ),
        .slink_obi_cfg   ( SlinkObiCfg            )
    ) i_serial_link_1 (
        .clk_i             ( clk_1              ),
        .rst_ni            ( rst_1_n            ),
        .testmode_i        ( 1'b0               ),
        .obi_in_req_i      ( obi_in_req_1       ),
        .obi_in_rsp_o      ( obi_in_rsp_1       ),
        .obi_out_req_o     ( obi_out_req_1      ),
        .obi_out_rsp_i     ( obi_out_rsp_1      ),
        .obi_reg_req_i     ( obi_reg_req_1      ),
        .obi_reg_rsp_o     ( obi_reg_rsp_1      ),
        .ddr_rcv_clk_i     ( ddr_rcv_clk_2      ),
        .ddr_rcv_clk_o     ( ddr_rcv_clk_1      ),
        .ddr_i             ( ddr_i              ),
        .ddr_o             ( ddr_o              ),
        .credit_recv_clk_i ( credit_recv_clk_i  ),
        .credit_rtrn_clk_o ( credit_rtrn_clk_o  )
    );

    // second serial instance
    slink #(
        .obi_req_t       ( obi_req_t        ),
        .obi_rsp_t       ( obi_rsp_t        ),
        .a_optional_t   ( obi_a_optional_t  ),
        .r_optional_t   ( obi_r_optional_t  ),
        // .a_chan_t        ( obi_a_chan_t     ),
        // .r_chan_t        ( obi_r_chan_t     ),
        .a_chan_write_t  ( slink_obi_a_chan_write_t   ),
        .a_chan_read_t   ( slink_obi_a_chan_read_t    ),
        .r_chan_write_t  ( slink_obi_r_chan_write_t   ),
        .r_chan_read_t   ( slink_obi_r_chan_read_t    ),
        .slink_obi_cfg   ( SlinkObiCfg            )
    ) i_serial_link_2 (
        .clk_i             ( clk_2              ),
        .rst_ni            ( rst_2_n            ),
        .testmode_i        ( 1'b0               ),
        .obi_in_req_i      ( obi_in_req_2       ),
        .obi_in_rsp_o      ( obi_in_rsp_2       ),
        .obi_out_req_o     ( obi_out_req_2      ),
        .obi_out_rsp_i     ( obi_out_rsp_2      ),
        .obi_reg_req_i     ( obi_reg_req_2      ),
        .obi_reg_rsp_o     ( obi_reg_rsp_2      ),
        .ddr_rcv_clk_i     ( ddr_rcv_clk_1      ),
        .ddr_rcv_clk_o     ( ddr_rcv_clk_2      ),
        .ddr_i             ( ddr_o              ),
        .ddr_o             ( ddr_i              ),
        .credit_recv_clk_i ( credit_rtrn_clk_o  ),
        .credit_rtrn_clk_o ( credit_recv_clk_i  )
    );

    // OBI DV interfaces
    OBI_BUS_DV #(
        .OBI_CFG        ( ObiCfg          ),
        .obi_a_optional_t ( obi_a_optional_t ),
        .obi_r_optional_t ( obi_r_optional_t )
    ) obi_in_1  (clk_1, rst_1_n),
      obi_out_1 (clk_1, rst_1_n),
      obi_reg_1 (clk_1, rst_1_n);

    OBI_BUS_DV #(
        .OBI_CFG        ( ObiCfg          ),
        .obi_a_optional_t ( obi_a_optional_t ),
        .obi_r_optional_t ( obi_r_optional_t )
    ) obi_in_2  (clk_2, rst_2_n),
      obi_out_2 (clk_2, rst_2_n),
      obi_reg_2 (clk_2, rst_2_n);


    assign obi_out_1.err = 1'b0;
    assign obi_out_2.err = 1'b0;

    `OBI_CONNECT_MANAGER(obi_in_1, obi_in_req_1, obi_in_rsp_1);
    `OBI_CONNECT_MANAGER(obi_in_2, obi_in_req_2, obi_in_rsp_2);

    `OBI_CONNECT_SUBORDINATE(obi_out_1, obi_out_req_1, obi_out_rsp_1);
    `OBI_CONNECT_SUBORDINATE(obi_out_2, obi_out_req_2, obi_out_rsp_2);

    `OBI_CONNECT_MANAGER(obi_reg_1, obi_reg_req_1, obi_reg_rsp_1);
    `OBI_CONNECT_MANAGER(obi_reg_2, obi_reg_req_2, obi_reg_rsp_2);
    

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

    typedef obi_rand_manager_fixed #(
        .ObiCfg           ( ObiCfg           ),
        .obi_a_optional_t ( obi_a_optional_t ),
        .obi_r_optional_t ( obi_r_optional_t ),
        .TA               ( 100ps            ),
        .TT               ( 500ps            ),
        .MinAddr          ( 32'h1000_0000    ),
        .MaxAddr          ( 32'hffff_ffff    ),
        .AMinWaitCycles   ( 0                ),
        .AMaxWaitCycles   ( 10               ),
        .RMinWaitCycles   ( 0                ),
        .RMaxWaitCycles   ( 10               )
    ) obi_rand_manager_t;

    typedef obi_test::obi_rand_subordinate #(
        .ObiCfg         ( ObiCfg            ),
        .obi_a_optional_t ( obi_a_optional_t ),
        .obi_r_optional_t ( obi_r_optional_t ),
        .TA             ( 100ps             ),
        .TT             ( 500ps             ),
        .AMinWaitCycles ( 0                 ),
        .AMaxWaitCycles ( 10                ),
        .RMinWaitCycles ( 0                 ),
        .RMaxWaitCycles ( 10                )
    ) obi_rand_subordinate_t;

    static obi_rand_manager_t obi_rand_manager_1 = new ( obi_in_1,  "obi_mst_1" );
    static obi_rand_manager_t obi_rand_manager_2 = new ( obi_in_2,  "obi_mst_2" );

    static obi_rand_subordinate_t obi_rand_subordinate_1 = new ( obi_out_1, "obi_slv_1" );
    static obi_rand_subordinate_t obi_rand_subordinate_2 = new ( obi_out_2, "obi_slv_2" );

    static obi_driver_t obi_reg_drv_1 = new ( obi_reg_1 );
    static obi_driver_t obi_reg_drv_2 = new ( obi_reg_2 );



    logic [1:0] mst_done;
    logic [1:0] cfg_done;

    // By default perform TestDuration transactions per side
    int NumReqs_1 = TestDuration;
    int NumReqs_2 = TestDuration;

    initial begin : stimuli_process
        obi_reg_drv_1.reset_manager();
        obi_reg_drv_2.reset_manager();
        fork
            wait_for_reset_1();
            wait_for_reset_2();
        join
        $display("[SYS] Reset complete");
        fork
            start_link(obi_reg_drv_1, 1);
            start_link(obi_reg_drv_2, 2);
        join
        $display("[SYS] Links are ready");
        while (mst_done != '1) begin
            @(posedge clk_1);
        end
        stop_sim();
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
        $display("OBI BW %0d/%0d (sent/rcv) Mbit/s @ %0d/%0d MHz (SoC/PHY)",
            data_sent * 1000 / (end_cycle - start_cycle),
            data_received * 1000 / (end_cycle - start_cycle),
            1000 / TckSys1,
            1000 / TckSys1 / 8);
        mst_done[0] = 1;
    end

    // Manager on side 2
    initial begin
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

    task automatic cfg_write(obi_driver_t drv, cfg_addr_t addr, cfg_data_t data);
        cfg_data_t rdata;
        obi_id_t rid;
        logic err;
        obi_r_optional_t r_optional;
        drv.send_a(addr, 1'b1, 4'b1111, data, 0, '0);
        drv.recv_r(rdata, rid, err, r_optional);
        assert (!err) else $error("Not able to write cfg reg");
    endtask

    task automatic cfg_read(obi_driver_t drv, cfg_addr_t addr, output cfg_data_t data);
        obi_id_t rid;
        logic err;
        obi_r_optional_t r_optional;
        drv.send_a(addr, 1'b0, 4'b1111, '0, 0, '0);
        drv.recv_r(data, rid, err, r_optional);
        assert (!err) else $error("Not able to read cfg reg");
    endtask

    task automatic start_link(obi_driver_t drv, int id);
        automatic cfg_data_t data;
        $display("[DDR%0d]: Writing registers...", id);
        cfg_write(drv, `SLINK_REG_NODE_ID_REG_ADDR, id+8);
        // Wait for some clock cycles
        repeat(10) drv.cycle_end();
        $display("[DDR%0d] Reading registers...",id);
        cfg_read(drv, `SLINK_REG_NODE_ID_REG_ADDR, data);
        $display("[DDR%0d] @0x%08X: 0x%08X",id, `SLINK_REG_NODE_ID_REG_ADDR, data);
        cfg_read(drv, `SLINK_REG_TX_PHY_CLK_DIV_0_REG_ADDR, data);
        $display("[DDR%0d] @0x%08X: 0x%08X",id, `SLINK_REG_TX_PHY_CLK_DIV_0_REG_ADDR, data);
        $display("[DDR%0d] Link is ready", id);
    endtask;

    task automatic stop_sim();
        repeat(50) begin
            @(posedge clk_1);
        end
        $display("[SYS] Simulation Stopped (%d ns)", $time);
        $stop();
    endtask

endmodule : tb_obi_slink

