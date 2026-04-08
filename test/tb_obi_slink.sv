// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

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

module tb_obi_slink;

  import slink_reg_pkg::*;
  import slink_pkg::*;
  import obi_pkg::*;
  import obi_test_fix_pkg::*;

  `include "obi/typedef.svh"
  `include "obi/assign.svh"
  `include "slink_addrmap.svh"
  `include "../include/slink_obi/typedef.svh"

  // ================================================================
  //  Parameters
  // ================================================================
  localparam int unsigned NumNodes     = 16;
  localparam int unsigned TestDuration = 15;  // transactions per node per destination

  localparam int unsigned MemDepth    = 256;
  localparam int unsigned AddrIdxBits = $clog2(MemDepth);
  localparam int unsigned MemByteSize = MemDepth * (32 / 8);  // 0x400

  localparam int unsigned ObiIdWidth    = 3;
  localparam int unsigned ObiAddrWidth  = 32;
  localparam int unsigned ObiDataWidth  = 32;
  localparam int unsigned RegAddrWidth  = 32;
  localparam int unsigned RegDataWidth  = 32;
  localparam bit          UseByteEnable = 1;
  localparam bit          UseOptional   = 0;

  localparam obi_cfg_t ObiCfg = obi_default_cfg(
      ObiAddrWidth, ObiDataWidth, ObiIdWidth, ObiMinimalOptionalConfig);
  localparam slink_obi_cfg_t SlinkObiCfg = slink_obi_cfg(
      ObiAddrWidth, ObiDataWidth, ObiDataWidth, ObiIdWidth, UseByteEnable, UseOptional);

  `OBI_TYPEDEF_DEFAULT_ALL(obi, ObiCfg)
  `SLINK_OBI_TYPEDEF_DEFAULT(slink_obi, SlinkObiCfg)

  typedef logic [ObiIdWidth-1:0]    obi_id_t;
  typedef logic [RegAddrWidth-1:0]  cfg_addr_t;
  typedef logic [RegDataWidth-1:0]  cfg_data_t;
  typedef logic [ObiDataWidth-1:0]  data_t;

  // Elaboration-time sanity checks
  initial begin
    assert (NumNodes * TestDuration <= MemDepth)
      else $fatal(1, "MemDepth (%0d) too small for NumNodes*TestDuration (%0d)", MemDepth, NumNodes * TestDuration);
    assert (NumNodes <= 16)
      else $fatal(1, "NumNodes (%0d) > 16, addr[31:28] only holds 16 IDs", NumNodes);
  end

  // ================================================================
  //  Shared memory model
  //
  //  mem[n][w]          : physical word w in node n's subordinate RAM
  //  expected_mem[n][w] : golden reference
  //
  //  Source-partitioned layout per destination node n:
  //    words [s*TestDuration .. (s+1)*TestDuration-1] written by node s
  // ================================================================
  data_t mem          [NumNodes][MemDepth];
  data_t expected_mem [NumNodes][MemDepth];

  int unsigned node_errors [NumNodes];
  int unsigned node_checks [NumNodes];

  // ================================================================
  //  Phase barriers (bit i set exclusively by proc_test[i])
  //
  //  link_ready : link configuration done
  //  write_done : all pipelined writes committed
  //  read_done  : all pipelined reads verified — used by proc_main
  // ================================================================
  logic [NumNodes-1:0] link_ready = '0;
  logic [NumNodes-1:0] write_done = '0;
  logic [NumNodes-1:0] read_done  = '0;

  // ================================================================
  //  Physical signals
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

  // ================================================================
  //  DV driver type
  // ================================================================
  typedef obi_test::obi_driver #(
      .ObiCfg           ( ObiCfg           ),
      .obi_a_optional_t ( obi_a_optional_t ),
      .obi_r_optional_t ( obi_r_optional_t ),
      .TA               ( 100ps            ),
      .TT               ( 500ps            )
  ) obi_driver_t;

  // ================================================================
  //  Module-level helper tasks
  // ================================================================

  task automatic cfg_write(obi_driver_t drv, cfg_addr_t addr, cfg_data_t wdata);
    automatic cfg_data_t       rdata;
    automatic obi_id_t         rid;
    automatic logic            err;
    automatic obi_r_optional_t r_opt;
    drv.send_a(addr, 1'b1, 4'b1111, wdata, '0, '0);
    drv.recv_r(rdata, rid, err, r_opt);
    assert (!err) else $error("cfg_write: error response at 0x%08X", addr);
  endtask

  task automatic cfg_read(obi_driver_t drv, cfg_addr_t addr, output cfg_data_t data);
    automatic obi_id_t         rid;
    automatic logic            err;
    automatic obi_r_optional_t r_opt;
    drv.send_a(addr, 1'b0, 4'b1111, '0, '0, '0);
    drv.recv_r(data, rid, err, r_opt);
    assert (!err) else $error("cfg_read: error response at 0x%08X", addr);
  endtask

  task automatic start_link(obi_driver_t drv, int unsigned node_id);
    automatic cfg_data_t data;
    $display("[Node %0d] Configuring, setting NODE_ID = %0d", node_id, node_id);
    cfg_write(drv, `SLINK_REG_NODE_ID_REG_ADDR, cfg_data_t'(node_id));
    repeat (10) drv.cycle_end();
    cfg_read(drv, `SLINK_REG_NODE_ID_REG_ADDR,           data);
    $display("[Node %0d] NODE_ID_REG       = 0x%08X", node_id, data);
    cfg_read(drv, `SLINK_REG_TX_PHY_CLK_DIV_0_REG_ADDR, data);
    $display("[Node %0d] TX_PHY_CLK_DIV_0 = 0x%08X", node_id, data);
    $display("[Node %0d] Link configured.", node_id);
  endtask

  // ================================================================
  //  Generate: one ring node per iteration
  // ================================================================
  generate
    for (genvar i = 0; i < NumNodes; i++) begin : gen_nodes

      localparam int unsigned NEXT = (i + 1) % NumNodes;

      // Clock / reset
      clk_rst_gen #(
          .ClkPeriod    ( 50ns + i * 2ns ),
          .RstClkCycles ( 1              )
      ) i_clk_rst (
          .clk_o  ( clk[i]   ),
          .rst_no ( rst_n[i] )
      );

      // SLINK instance
      slink #(
          .obi_req_t       ( obi_req_t               ),
          .obi_rsp_t       ( obi_rsp_t               ),
          .a_optional_t    ( obi_a_optional_t         ),
          .r_optional_t    ( obi_r_optional_t         ),
          .a_chan_write_t  ( slink_obi_a_chan_write_t ),
          .a_chan_read_t   ( slink_obi_a_chan_read_t  ),
          .r_chan_write_t  ( slink_obi_r_chan_write_t ),
          .r_chan_read_t   ( slink_obi_r_chan_read_t  ),
          .slink_obi_cfg   ( SlinkObiCfg             )
      ) i_slink (
          .clk_i             ( clk[i]            ),
          .rst_ni            ( rst_n[i]           ),
          .testmode_i        ( 1'b0               ),
          .obi_in_req_i      ( obi_in_req[i]     ),
          .obi_in_rsp_o      ( obi_in_rsp[i]     ),
          .obi_out_req_o     ( obi_out_req[i]    ),
          .obi_out_rsp_i     ( obi_out_rsp[i]    ),
          .obi_reg_req_i     ( obi_reg_req[i]    ),
          .obi_reg_rsp_o     ( obi_reg_rsp[i]    ),
          .ddr_rcv_clk_i     ( ddr_rcv_clk[i]    ),
          .ddr_rcv_clk_o     ( ddr_rcv_clk[NEXT] ),
          .ddr_i             ( ddr_link[i]        ),
          .ddr_o             ( ddr_link[NEXT]     ),
          .credit_recv_clk_i ( credit_clk[NEXT]  ),
          .credit_rtrn_clk_o ( credit_clk[i]     )
      );

      // OBI DV interfaces (manager + reg sides only)
      OBI_BUS_DV #(
          .OBI_CFG          ( ObiCfg           ),
          .obi_a_optional_t ( obi_a_optional_t ),
          .obi_r_optional_t ( obi_r_optional_t )
      ) obi_in_if  ( clk[i], rst_n[i] ),
        obi_reg_if ( clk[i], rst_n[i] );

      `OBI_CONNECT_MANAGER(obi_in_if,  obi_in_req[i],  obi_in_rsp[i])
      `OBI_CONNECT_MANAGER(obi_reg_if, obi_reg_req[i], obi_reg_rsp[i])

      // ------------------------------------------------------------
      //  Behavioural RAM subordinate
      //
      //  addr[31:28] = routing bits (consumed by slink before delivery)
      //  addr[27:0]  = local byte address → word index addr[AddrIdxBits+1:2]
      //
      //  OBI minimal model: gnt=1 always, rvalid one cycle after req.
      // ------------------------------------------------------------
      logic    sub_rvalid_q;
      data_t   sub_rdata_q;
      obi_id_t sub_rid_q;

      assign obi_out_rsp[i].gnt          = 1'b1;
      assign obi_out_rsp[i].rvalid       = sub_rvalid_q;
      assign obi_out_rsp[i].r.rdata      = sub_rdata_q;
      assign obi_out_rsp[i].r.rid        = sub_rid_q;
      assign obi_out_rsp[i].r.err        = 1'b0;
      assign obi_out_rsp[i].r.r_optional = '0;

      always @(posedge clk[i] or negedge rst_n[i]) begin
        if (!rst_n[i]) begin
          sub_rvalid_q <= 1'b0;
          sub_rdata_q  <= '0;
          sub_rid_q    <= '0;
        end else begin
          sub_rvalid_q <= obi_out_req[i].req;
          sub_rid_q    <= obi_out_req[i].a.aid;

          if (obi_out_req[i].req) begin
            if (obi_out_req[i].a.we) begin
              // Byte-enable write
              for (int b = 0; b < ObiDataWidth / 8; b++) begin
                if (obi_out_req[i].a.be[b])
                  mem[i][obi_out_req[i].a.addr[AddrIdxBits+1:2]][b*8 +: 8]
                      <= obi_out_req[i].a.wdata[b*8 +: 8];
              end
              sub_rdata_q <= '0;
            end else begin
              // Read
              sub_rdata_q <= mem[i][obi_out_req[i].a.addr[AddrIdxBits+1:2]];
            end
          end else begin
            sub_rdata_q <= '0;
          end
        end
      end

      // ------------------------------------------------------------
      //  Per-node test process
      //
      //  Phase 0 — link configuration          (barrier: link_ready)
      //  Phase 1 — pipelined writes, all nodes (barrier: write_done)
      //  Phase 2 — pipelined read-back, check  (barrier: read_done)
      // ------------------------------------------------------------
      initial begin : proc_test

        automatic int unsigned src_node = i;

        automatic obi_driver_t mgr     = new(obi_in_if);
        automatic obi_driver_t reg_drv = new(obi_reg_if);

        // waddr/wdata indexed [destination_node][transaction_index]
        automatic cfg_addr_t waddr [NumNodes][TestDuration];
        automatic data_t     wdata [NumNodes][TestDuration];

        automatic int unsigned local_errs = 0;

        mgr.reset_manager();
        reg_drv.reset_manager();

        @(posedge rst_n[i]);
        $display("[Node %0d] Reset released.", i);

        // ==========================================================
        //  Phase 0: link configuration
        //
        //  Write the 0-indexed node ID into the slink's NODE_ID_REG.
        //  This must match addr[31:28] used when addressing this node.
        // ==========================================================
        start_link(reg_drv, i);
        link_ready[i] = 1'b1;
        wait (link_ready == '1);
        $display("[Node %0d] All links ready, entering write phase.", i);

        // ==========================================================
        //  Phase 1: pipelined writes to ALL nodes (including self)
        //
        //  Source partition:  local_word_idx = src_node * TestDuration + t
        //  Full address:      (dst_node_id << 28) | (local_word_idx << 2)
        //
        //  Golden reference written before the fork so it is visible
        //  to the read-back phase without any race condition.
        // ==========================================================
        for (int d = 0; d < NumNodes; d++) begin
          for (int t = 0; t < TestDuration; t++) begin
            automatic int unsigned w = src_node * TestDuration + t;
            waddr[d][t]        = (cfg_addr_t'(d) << 28) | cfg_addr_t'(w << 2);
            wdata[d][t]        = data_t'($urandom());
            expected_mem[d][w] = wdata[d][t];
          end
        end

        fork
          begin : wr_sender
            for (int d = 0; d < NumNodes; d++) begin
              if (i == d) continue;
              for (int t = 0; t < TestDuration; t++)
                mgr.send_a(waddr[d][t], 1'b1, 4'b1111, wdata[d][t], obi_id_t'(t[0]), '0);
            end
          end
          begin : wr_collector
            for (int d = 0; d < NumNodes; d++) begin
              if (i == d) continue;
              for (int t = 0; t < TestDuration; t++) begin
                automatic data_t           rdata;
                automatic obi_id_t         rid;
                automatic logic            err;
                automatic obi_r_optional_t r_opt;
                mgr.recv_r(rdata, rid, err, r_opt);
                node_checks[i]++;
                if (err) begin
                  $error("[WR Node %0d->%0d] t=%0d addr=0x%08X: unexpected err=1 on write response", i, d, t, waddr[d][t]);
                  local_errs++;
                end 
              end
            end
          end
        join

        write_done[i] = 1'b1;
        wait (write_done == '1);  // all nodes committed; safe to read
        $display("[Node %0d] All writes committed, entering read phase.", i);

        // ==========================================================
        //  Phase 2: pipelined read-back and scoreboard
        //
        //  Re-issue all addresses as reads and compare each response
        //  against expected_mem[d][src_node * TestDuration + t].
        // ==========================================================
        fork
          begin : rd_sender
            for (int d = 0; d < NumNodes; d++) begin
              if (i == d) continue;
              for (int t = 0; t < TestDuration; t++)
                mgr.send_a(waddr[d][t], 1'b0, 4'b1111, '0, obi_id_t'(t[0]), '0);
            end
          end
          begin : rd_collector
            for (int d = 0; d < NumNodes; d++) begin
              if (i == d) continue;
              for (int t = 0; t < TestDuration; t++) begin
                automatic data_t           rdata;
                automatic obi_id_t         rid;
                automatic logic            err;
                automatic obi_r_optional_t r_opt;
                automatic int unsigned     w = src_node * TestDuration + t;
                mgr.recv_r(rdata, rid, err, r_opt);
                node_checks[i]++;
                if (err) begin
                  $error("[RD Node %0d<-%0d] t=%0d addr=0x%08X: unexpected err=1 on read response", i, d, t, waddr[d][t]);
                  local_errs++;
                end else if (rdata !== expected_mem[d][w]) begin
                  $error("[RD Node %0d<-%0d] t=%0d addr=0x%08X: DATA MISMATCH got=0x%08X exp=0x%08X", i, d, t, waddr[d][t], rdata, expected_mem[d][w]);
                  local_errs++;
                end
              end
            end
          end
        join

        node_errors[i]  = local_errs;
        read_done[i]    = 1'b1;
        $display("[Node %0d] All reads verified, %0d errors / %0d checks.", i, local_errs, node_checks[i]);

      end : proc_test

    end // for genvar i
  endgenerate

  // ================================================================
  //  Main control process
  // ================================================================
  initial begin : proc_main
    automatic int unsigned total_errors = 0;
    automatic int unsigned total_checks = 0;

    // Zero-initialise all shared state before any proc_test starts
    for (int n = 0; n < NumNodes; n++) begin
      node_errors[n] = 0;
      node_checks[n] = 0;
      for (int a = 0; a < MemDepth; a++) begin
        mem[n][a]          = '0;
        expected_mem[n][a] = '0;
      end
    end

    // Wait for all nodes to complete their read-back phase
    wait (read_done == '1);
    repeat (100) @(posedge clk[0]);

    for (int n = 0; n < NumNodes; n++) begin
      total_errors += node_errors[n];
      total_checks += node_checks[n];
    end

    $display("==========================================================");
    $display("[SYS] Simulation complete at %0t", $time);
    $display("[SYS] Nodes        : %0d", NumNodes);
    $display("[SYS] Total checks : %0d (%0d per node)", total_checks, total_checks / NumNodes);
    $display("[SYS] Total errors : %0d", total_errors);
    if (total_errors == 0)
      $display("[SYS] *** ALL TESTS PASSED ***");
    else
      $display("[SYS] *** %0d TEST(S) FAILED ***", total_errors);
    $display("==========================================================");
    $stop();
  end

endmodule : tb_obi_slink