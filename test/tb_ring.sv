// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Author: Llorenc Muela Hausmann <lmuela@ethz.ch>
// Author: Fabian Aegerter        <faegerter@ethz.ch>


`define OBI_CONNECT_MANAGER(_if, _req, _rsp) \
    assign _req.a.addr       = _if.addr; \
    assign _req.a.we         = _if.we; \
    assign _req.a.be         = _if.be; \
    assign _req.a.wdata      = _if.wdata; \
    assign _req.a.aid        = _if.aid; \
    assign _req.a.a_optional = _if.a_optional; \
    assign _req.req          = _if.req; \
    assign _if.gnt           = _rsp.gnt; \
    assign _if.rvalid        = _rsp.rvalid; \
    assign _if.rdata         = _rsp.r.rdata; \
    assign _if.rid           = _rsp.r.rid; \
    assign _if.err           = _rsp.r.err; \
    assign _if.r_optional    = _rsp.r.r_optional;

`define OBI_CONNECT_SUBORDINATE(_if, _req, _rsp) \
    assign _if.addr          = _req.a.addr; \
    assign _if.we            = _req.a.we; \
    assign _if.be            = _req.a.be; \
    assign _if.wdata         = _req.a.wdata; \
    assign _if.aid           = _req.a.aid; \
    assign _if.a_optional    = _req.a.a_optional; \
    assign _if.req           = _req.req; \
    assign _rsp.gnt          = _if.gnt; \
    assign _rsp.rvalid       = _if.rvalid; \
    assign _rsp.r.rdata      = _if.rdata; \
    assign _rsp.r.rid        = _if.rid; \
    assign _rsp.r.err        = _if.err; \
    assign _rsp.r.r_optional = _if.r_optional;

typedef enum logic [2:0] {
    TEST_BASELINE = 3'b000,
    TEST_HOTSPOT = 3'b001,
    TEST_ALL_TO_ALL = 3'b010,
    TEST_ONE_TO_ALL = 3'b011
} test_e;


module tb_ring#(
    parameter int unsigned NumNodes = 4,
    parameter int unsigned BurstLen = 4096,
    parameter int unsigned MemSize = BurstLen * 4,
    parameter int unsigned MaxOutstanding = 2,
    parameter bit EnDynPayloadSize = 1'b1,
    parameter int unsigned TxFifoDepth          = 3,
    parameter int unsigned MaxOutstandingReqIn  = 2,  // /!\ Increasing this will increase the OBI ID width, hence payload, hence decrease throughput
    parameter int unsigned MaxInflightReqOut    = 2,
    parameter int unsigned ClkDiv = 8,
    parameter test_e TestType = TEST_BASELINE
);

    import slink_reg_pkg::*;
    import slink_pkg::*;
    import obi_pkg::*;

    `include "obi/typedef.svh"
    `include "obi/assign.svh"
    `include "slink_addrmap.svh"
    `include "../include/slink_obi/typedef.svh"

    // ================================================================
    //  Experiment parameters
    // ================================================================
    localparam int unsigned ObiIdWidth     = 1;
    localparam int unsigned ObiAddrWidth   = 32;
    localparam int unsigned ObiDataWidth   = 32;
    localparam bit          UseByteEnable  = 1;
    localparam bit          UseOptional    = 0;

    localparam int unsigned RecvFifoPayloadDepth = 2;

    localparam obi_cfg_t ObiCfg = obi_default_cfg(
        ObiAddrWidth, ObiDataWidth, ObiIdWidth, ObiMinimalOptionalConfig);
    localparam slink_obi_cfg_t SlinkObiCfg = slink_obi_cfg(
        ObiAddrWidth, ObiDataWidth, ObiDataWidth, $clog2(MaxOutstandingReqIn > 1 ? MaxOutstandingReqIn : 2),
        UseByteEnable, UseOptional);

    `OBI_TYPEDEF_DEFAULT_ALL(obi, ObiCfg)
    `SLINK_OBI_TYPEDEF_DEFAULT(slink_obi, SlinkObiCfg)

    typedef logic [ObiDataWidth-1:0]  data_t;

    // ================================================================
    //  DV driver and Node specialization
    // ================================================================
    typedef obi_test::obi_driver #(
        .ObiCfg           ( ObiCfg           ),
        .obi_a_optional_t ( obi_a_optional_t ),
        .obi_r_optional_t ( obi_r_optional_t ),
        .TA               ( 100ps            ),
        .TT               ( 500ps            )
    ) obi_driver_t;

    // Include the test framework AFTER the driver typedef so the
    // parameterized Node specialization below sees the right types.
    `include "perf_monitor.svh"
    `include "node.svh"
    `include "node_traffic.svh"

    typedef Node #(
        .obi_mgr_drv_t ( obi_driver_t ),
        .obi_reg_drv_t ( obi_driver_t ),
        .obi_sbr_drv_t ( obi_driver_t ),
        .obi_req_mgr_t ( obi_req_t    ),
        .obi_rsp_mgr_t ( obi_rsp_t    ),
        .obi_req_sbr_t ( obi_req_t    ),
        .obi_rsp_sbr_t ( obi_rsp_t    ),
        .MemSize       ( MemSize  )
    ) node_t;

    typedef NodeTraffic #( node_t ) traffic_t;

    // ================================================================
    //  Top-level signals
    // ================================================================
    logic clk   [NumNodes];
    logic rst_n [NumNodes];

    obi_req_t obi_in_req  [NumNodes];
    obi_rsp_t obi_in_rsp  [NumNodes];
    obi_req_t obi_out_req [NumNodes];
    obi_rsp_t obi_out_rsp [NumNodes];
    obi_req_t obi_reg_req [NumNodes];
    obi_rsp_t obi_reg_rsp [NumNodes];

    logic [NumChannels-1:0] ddr_rcv_clk [NumNodes];
    wire  [NumNodes-1:0][NumChannels*NumLanes-1:0] ddr_link;
    wire  credit_clk [NumNodes];

    // Framework state shared across nodes
    node_t           nodes [NumNodes];
    SlinkPerfMonitor perf;

    // Barriers
    bit                  perf_ready     = 1'b0;
    logic [NumNodes-1:0] node_obj_ready = '0;
    logic [NumNodes-1:0] link_ready     = '0;
    logic [NumNodes-1:0] write_done     = '0;


    // ================================================================
    //  Printing functions
    // ================================================================
    function void print_info (string m); $display("[TB_RING][INFO]  %s", m); endfunction
    function void print_warn (string m); $display("[TB_RING][WARN]  %s", m); endfunction
    function void print_error(string m); $error  ("[TB_RING][ERROR] %s", m); endfunction
    function void print_fatal(string m); $fatal(1,"[TB_RING][FATAL] %s", m); endfunction


    task automatic run_baseline(int hops, int active_count = 1, bit write = 1'b1);
        if (hops == 0 || hops == NumNodes) print_fatal("Hops must be greater than 0 and less than NumNodes");
        if (active_count == 0 || active_count > NumNodes) print_fatal("Active count must be greater than 0 and less than NumNodes");
        for (int i = 0; i < active_count; i++) begin
            automatic int unsigned mm;
            automatic int src = i;
            automatic int dest = (src + hops) % NumNodes;
            fork
                begin
                    if (write) traffic_t::burst_writes(nodes[src], nodes[dest], BurstLen);
                    else       traffic_t::burst_read_back(nodes[src], nodes[dest], BurstLen, mm);
                    nodes[src].drain();
                end
            join_none
        end
        wait fork;
    endtask

    task automatic run_hotspot(bit write = 1'b1); // a.k.a. all-to-one
        for (int i  = 1; i < NumNodes; i++) begin
            automatic int unsigned mm;
            automatic int src = i;
            fork
                begin
                    if (write) traffic_t::burst_writes(nodes[src], nodes[0], BurstLen);
                    else       traffic_t::burst_read_back(nodes[src], nodes[0], BurstLen, mm);
                end
            join_none
        end
        wait fork;
    endtask

    task automatic run_all_to_all(bit write = 1'b1);
        for (int i  = 0; i < NumNodes; i++) begin
            automatic int src = i;
            automatic node_t::txn_desc_t descs[$];
            for (int k = 0; k < BurstLen/NumNodes; k++) begin
                for (int j = 0; j < NumNodes; j++) begin
                    if (j != i) begin
                        if (write) descs.push_back(traffic_t::make_write(j, 0, 22));
                        else       descs.push_back(traffic_t::make_read(j, 0));
                    end
                end
            end
            fork
                traffic_t::run_descs(nodes[src], descs);
            join_none
        end
        wait fork;
    endtask

    task automatic run_one_to_all(bit write = 1'b1);
        automatic node_t::txn_desc_t descs[$];
        for (int j = 0; j < BurstLen; j++) begin
            for (int i = 1; i < NumNodes; i++) begin
                if (write) descs.push_back(traffic_t::make_write(i, j*4, 22));
                else       descs.push_back(traffic_t::make_read(i, j*4));
            end
        end
        traffic_t::run_descs(nodes[0], descs);
    endtask

    task automatic run_token_propagation();
        automatic bit passed = 1'b1;
        fork
            traffic_t::burst_writes(nodes[0], nodes[1], BurstLen, .rnd_data(1'b0), .data(22));
        join_none
        for (int i  = 0; i < NumNodes; i++) begin
            automatic node_t::txn_desc_t descs[$];
            automatic node_t me = nodes[i];
            automatic int src = i;
            automatic int unsigned dst = (i + 1) % NumNodes;
            fork
                begin
                    for (int k = 0; k < BurstLen; k++) begin
                        wait (me.mem_read_word(k*4) != '0);
                        if (src != 0) begin
                            descs = '{traffic_t::make_write(dst, k*4, me.mem_read_word(k*4))};
                            traffic_t::run_descs(me, descs);
                        end
                    end
                end
            join_none
        end
        wait fork;
        for (int i = 0; i < BurstLen; i++) begin
            if (nodes[0].mem_read_word(i*4) != 22) begin
                passed = 1'b0;
                break;
            end
        end
        if (passed) print_info("PASS: Token propagation passed");
        else print_info("FAIL: Token propagation failed");
    endtask

    task automatic run_test_functionality();
        automatic bit passed = 1'b1;
        for (int i  = 0; i < NumNodes; i++) begin
            automatic int          src = i;
            automatic int unsigned dst = (i + 1) % NumNodes;
            automatic int unsigned mm;
            fork
                begin
                    traffic_t::burst_writes(nodes[src], nodes[dst], BurstLen);

                    write_done[src] = 1'b1;
                    wait (write_done == '1);
                    nodes[src].print_info("Writes done, entering READ-BACK phase.");

                    traffic_t::burst_read_back(nodes[src], nodes[dst], BurstLen, mm);
                    if (mm != 0) begin
                        nodes[src].print_info("FAIL: Mismatch");
                        passed = 1'b0;
                    end
                end
            join_none
        end
        wait fork;
        if (passed) print_info("PASS: Test functionality passed");
        else        print_error("FAIL: Test functionality failed");
    endtask

    task automatic run_scatter_compute_gather();
        automatic node_t::txn_desc_t descs[$];
        for (int i = 1; i < NumNodes; i++) begin
            // Matrix 1
            descs.push_back(traffic_t::make_write(i, 1, 1));
            descs.push_back(traffic_t::make_write(i, 2, 2));
            descs.push_back(traffic_t::make_write(i, 3, 3));
            descs.push_back(traffic_t::make_write(i, 4, 4));
            // Matrix 2
            descs.push_back(traffic_t::make_write(i, 5, 5));
            descs.push_back(traffic_t::make_write(i, 6, 6));
            descs.push_back(traffic_t::make_write(i, 7, 7));
            descs.push_back(traffic_t::make_write(i, 8, 8));
            // Go command
            descs.push_back(traffic_t::make_write(i, 0, 22));
        end
        traffic_t::run_descs(nodes[0], descs);
        for (int i = 1; i < NumNodes; i++) begin
            automatic int id = i;
            fork
                begin
                    automatic node_t::txn_desc_t descs_node[$];
                    automatic data_t result[4];
                    wait (nodes[id].mem_read_word(0) == 22);
                    result[0] = nodes[id].mem_read_word(1) * nodes[id].mem_read_word(5) + nodes[id].mem_read_word(2) * nodes[id].mem_read_word(7);
                    result[1] = nodes[id].mem_read_word(1) * nodes[id].mem_read_word(6) + nodes[id].mem_read_word(2) * nodes[id].mem_read_word(8);
                    result[2] = nodes[id].mem_read_word(3) * nodes[id].mem_read_word(5) + nodes[id].mem_read_word(4) * nodes[id].mem_read_word(7);
                    result[3] = nodes[id].mem_read_word(3) * nodes[id].mem_read_word(6) + nodes[id].mem_read_word(4) * nodes[id].mem_read_word(8);
                    nodes[id].mem_write_word(9, result[0], '1);
                    nodes[id].mem_write_word(10, result[1], '1);
                    nodes[id].mem_write_word(11, result[2], '1);
                    nodes[id].mem_write_word(12, result[3], '1);
                    descs_node.push_back(traffic_t::make_write(0, 4*id, result[0]));
                    descs_node.push_back(traffic_t::make_write(0, 4*id+1, result[1]));
                    descs_node.push_back(traffic_t::make_write(0, 4*id+2, result[2]));
                    descs_node.push_back(traffic_t::make_write(0, 4*id+3, result[3]));
                    #100ns; // Like if some important computations were happening
                    traffic_t::run_descs(nodes[id], descs_node);
                end
            join_none
        end
        wait fork;
        wait (nodes[0].mem_read_word(NumNodes*4-1) != 0);
    endtask


    // ================================================================
    //  Ring instantiation
    // ================================================================
    generate
        for (genvar gi = 0; gi < NumNodes; gi++) begin : gen_nodes
            localparam int unsigned NEXT = (gi + 1) % NumNodes;
            
            clk_rst_gen #(
                .ClkPeriod    ( 10ns ),
                // .ClkPeriod    ( 10ns + gi * 1ns ),
                .RstClkCycles ( 1    )
            ) i_clk_rst (
                .clk_o  ( clk[gi]   ),
                .rst_no ( rst_n[gi] )
            );

            slink #(
                .RecvFifoPayloadDepth ( RecvFifoPayloadDepth     ),
                .TxFifoDepth          ( TxFifoDepth              ),
                .MaxOutstandingReqIn  ( MaxOutstandingReqIn      ),
                .MaxInflightReqOut    ( MaxInflightReqOut        ),
                .obi_req_mgr_t        ( obi_req_t                ),
                .obi_rsp_mgr_t        ( obi_rsp_t                ),
                .obi_req_sbr_t        ( obi_req_t                ),
                .obi_rsp_sbr_t        ( obi_rsp_t                ),
                .obi_r_chan_sbr_t     ( obi_r_chan_t             ),
                .a_optional_t         ( obi_a_optional_t         ),
                .r_optional_t         ( obi_r_optional_t         ),
                .a_chan_write_t       ( slink_obi_a_chan_write_t ),
                .a_chan_read_t        ( slink_obi_a_chan_read_t  ),
                .r_chan_write_t       ( slink_obi_r_chan_write_t ),
                .r_chan_read_t        ( slink_obi_r_chan_read_t  ),
                .slink_obi_cfg        ( SlinkObiCfg              ),
                .EnDynPayloadSize     ( EnDynPayloadSize         )
            ) i_slink (
                .clk_i             ( clk[gi]            ),
                .rst_ni            ( rst_n[gi]          ),
                .testmode_i        ( 1'b0               ),
                .obi_in_req_i      ( obi_in_req[gi]     ),
                .obi_in_rsp_o      ( obi_in_rsp[gi]     ),
                .obi_out_req_o     ( obi_out_req[gi]    ),
                .obi_out_rsp_i     ( obi_out_rsp[gi]    ),
                .obi_reg_req_i     ( obi_reg_req[gi]    ),
                .obi_reg_rsp_o     ( obi_reg_rsp[gi]    ),
                .ddr_rcv_clk_i     ( ddr_rcv_clk[gi]    ),
                .ddr_rcv_clk_o     ( ddr_rcv_clk[NEXT]  ),
                .ddr_i             ( ddr_link[gi]       ),
                .ddr_o             ( ddr_link[NEXT]     ),
                .credit_recv_clk_i ( credit_clk[NEXT]   ),
                .credit_rtrn_clk_o ( credit_clk[gi]     )
            );

            OBI_BUS_DV #(
                .OBI_CFG          ( ObiCfg           ),
                .obi_a_optional_t ( obi_a_optional_t ),
                .obi_r_optional_t ( obi_r_optional_t )
            ) obi_in_if  ( clk[gi], rst_n[gi] ),
              obi_reg_if ( clk[gi], rst_n[gi] ),
              obi_out_if ( clk[gi], rst_n[gi] );

            `OBI_CONNECT_MANAGER(obi_in_if,  obi_in_req[gi],  obi_in_rsp[gi])
            `OBI_CONNECT_MANAGER(obi_reg_if, obi_reg_req[gi], obi_reg_rsp[gi])
            `OBI_CONNECT_SUBORDINATE(obi_out_if, obi_out_req[gi], obi_out_rsp[gi])

            // -------- Per-node test process --------
            initial begin : proc_node
                automatic obi_driver_t mgr_drv;
                automatic obi_driver_t reg_drv;
                automatic obi_driver_t sbr_drv;
                automatic node_t       me;
                automatic int unsigned dst;
                automatic int unsigned mm;

                automatic node_t::txn_desc_t inval_node;
                automatic node_t::txn_desc_t inval_addr;
                automatic node_t::txn_desc_t inval_self;
                automatic node_t::txn_desc_t descs[$];

                wait (perf_ready);

                mgr_drv = new(obi_in_if);
                reg_drv = new(obi_reg_if);
                sbr_drv = new(obi_out_if);

                me        = new(gi, mgr_drv, reg_drv, sbr_drv, MaxOutstanding, perf);
                nodes[gi] = me;
                node_obj_ready[gi] = 1'b1;

                me.init();
                me.link_bringup(ClkDiv, EnDdr ? ClkDiv/4 : 0, EnDdr ? (ClkDiv*3)/4 : ClkDiv/2);
                fork
                    me.run_sbr();
                join_none

                link_ready[gi] = 1'b1;
                wait (link_ready == '1);
            end
        end
    endgenerate


    // ================================================================
    //  Orchestrator
    // ================================================================
    initial begin : proc_main
        automatic int unsigned hops = 5;
        automatic int unsigned active_count = 1;

        if ($value$plusargs ("HOP=%0d", hops))
            print_info($sformatf("HOP=%0d", hops));
        if ($value$plusargs ("ACTIVE_COUNT=%0d", active_count))
            print_info($sformatf("ACTIVE_COUNT=%0d", active_count));
        

        perf = new("TB RING READ");
        perf_ready = 1'b1;

        wait (link_ready == '1);
        print_info("All nodes ready.");
        // ===================== READ =====================
        perf.mark_start();
        case (TestType)
            TEST_BASELINE: run_baseline(hops, active_count, .write(1'b0));
            TEST_HOTSPOT: run_hotspot(.write(1'b0));
            TEST_ALL_TO_ALL: run_all_to_all(.write(1'b0));
            TEST_ONE_TO_ALL: run_one_to_all(.write(1'b0));
            default: print_fatal("Invalid test type");
        endcase
        perf.mark_end();
        perf.report();
        // ===================== WRITE =====================
        perf.change_label("TB RING WRITE");
        perf.reset();
        perf.mark_start();
        case (TestType)
            TEST_BASELINE: run_baseline(hops, active_count, .write(1'b1));
            TEST_HOTSPOT: run_hotspot(.write(1'b1));
            TEST_ALL_TO_ALL: run_all_to_all(.write(1'b1));
            TEST_ONE_TO_ALL: run_one_to_all(.write(1'b1));
            default: print_fatal("Invalid test type");
        endcase
        perf.mark_end();
        perf.report();
        $stop;
    end

    // Safety timeout: never wait forever
    initial begin : proc_timeout
        #(100ms);
        print_error("TIMEOUT");
        $finish;
    end

endmodule
