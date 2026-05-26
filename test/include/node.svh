// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Authors:
//   - Llorenc Muela Hausmann <lmuela@ethz.ch>
//   - Fabian Aegerter        <faegerter@ethz.ch>
//
// Node: a reusable per-DUT abstraction for the Serial Link testbenches.

`ifndef NODE_SVH
`define NODE_SVH

`include "perf_monitor.svh"

import slink_reg_pkg::*;

class Node #(
    parameter type         obi_mgr_drv_t,
    parameter type         obi_reg_drv_t,
    parameter type         obi_sbr_drv_t,
    parameter type         obi_req_mgr_t,
    parameter type         obi_rsp_mgr_t,
    parameter type         obi_req_sbr_t,
    parameter type         obi_rsp_sbr_t,
    parameter int unsigned MemSize = 1024   // bytes
);

    //==========================================================
    // Types derived from the driver type parameters
    //==========================================================
    typedef logic [obi_mgr_drv_t::ObiCfg.AddrWidth-1:0]    addr_t;
    typedef logic [obi_mgr_drv_t::ObiCfg.DataWidth-1:0]    data_t;
    typedef logic [obi_mgr_drv_t::ObiCfg.DataWidth/8-1:0]  be_t;
    typedef logic [obi_mgr_drv_t::ObiCfg.IdWidth-1:0]      id_t;
    typedef obi_mgr_drv_t::obi_a_optional_t                a_optional_t;
    typedef obi_mgr_drv_t::obi_r_optional_t                r_optional_t;

    typedef logic [obi_reg_drv_t::ObiCfg.AddrWidth-1:0]    cfg_addr_t;
    typedef logic [obi_reg_drv_t::ObiCfg.DataWidth-1:0]    cfg_data_t;

    //==========================================================
    // Conventional metric tags (int so TBs can pass custom values)
    //==========================================================
    static const int TAG_NONE      = 0;
    static const int TAG_LOCAL_R   = 1;
    static const int TAG_LOCAL_W   = 2;
    static const int TAG_REMOTE_R  = 3;
    static const int TAG_REMOTE_W  = 4;
    static const int TAG_TRANSIT   = 5;
    static const int TAG_LOOP_R    = 6;
    static const int TAG_LOOP_W    = 7;
    static const int TAG_ERROR_R   = 8;
    static const int TAG_ERROR_W   = 9;
    static const int TAG_RAW_MODE  = 10;
    static const int TAG_USER0     = 100;
    static const int TAG_USER1     = 101;
    static const int TAG_USER2     = 102;
    static const int TAG_USER3     = 103;

    //==========================================================
    // Transaction descriptors / handles / results
    //==========================================================
    typedef struct {
        int unsigned dst_id;
        addr_t       local_addr;   // byte offset within destination memory
        logic        we;
        be_t         be;
        data_t       wdata;
        a_optional_t a_optional;
        int          tag;          // metric class, see TAG_* above
        logic        expect_err;
    } txn_desc_t;

    typedef struct {
        txn_desc_t   desc;
        id_t         aid;
        addr_t       full_addr;    // global_addr(dst_id, local_addr)
        realtime     t_issue;
        realtime     t_granted;
        bit          valid;
    } txn_handle_t;

    typedef struct {
        txn_handle_t handle;
        id_t         rid;
        data_t       rdata;
        logic        err;
        r_optional_t r_optional;
        realtime     t_complete;
        realtime     latency_time;
        longint unsigned latency_cyc;
        realtime     latency_time_from_granted;
        longint unsigned latency_cyc_from_granted;
    } txn_result_t;

    //==========================================================
    // Public fields
    //==========================================================
    int unsigned       node_id;
    obi_mgr_drv_t      obi_mgr;
    obi_reg_drv_t      obi_reg;
    obi_sbr_drv_t      obi_sbr;            // may be null (when TB drives sbr inline)

    // Per-node memory model (subordinate side)
    logic [7:0]        mem          [MemSize];
    logic [7:0]        expected_mem [MemSize];

    // Outstanding-transaction tracking
    int unsigned       max_outstanding;    // 0 == unlimited
    id_t               aid_counter;
    txn_handle_t       pending [$];
    semaphore          slot_sem;

    // Optional metrics monitor
    SlinkPerfMonitor   monitor;

    // Auto-measured clock period (used to convert realtime <-> cycles)
    realtime           clk_period;


    //==========================================================
    // Constructor
    //==========================================================
    function new(
        int unsigned     node_id,
        obi_mgr_drv_t    obi_mgr,
        obi_reg_drv_t    obi_reg,
        obi_sbr_drv_t    obi_sbr,
        int unsigned     max_outstanding = 0,
        SlinkPerfMonitor monitor         = null
    );
        this.node_id         = node_id;
        this.obi_mgr         = obi_mgr;
        this.obi_reg         = obi_reg;
        this.obi_sbr         = obi_sbr;
        this.max_outstanding = max_outstanding;
        this.monitor         = monitor;
        this.aid_counter     = '0;
        this.clk_period      = 1ns;
        if (max_outstanding > 0) this.slot_sem = new(max_outstanding);
        else                     this.slot_sem = null;
        foreach (this.mem[i])          this.mem[i]          = 8'h00;
        foreach (this.expected_mem[i]) this.expected_mem[i] = 8'h00;
    endfunction


    //==========================================================
    // Diagnostics
    //==========================================================
    function void print_info (string m); $display("[Node %2d][INFO]  %s", this.node_id, m); endfunction
    function void print_warn (string m); $display("[Node %2d][WARN]  %s", this.node_id, m); endfunction
    function void print_error(string m); $error  ("[Node %2d][ERROR] %s", this.node_id, m); endfunction
    function void print_fatal(string m); $fatal(1,"[Node %2d][FATAL] %s", this.node_id, m); endfunction


    //==========================================================
    // Cycle accounting
    //==========================================================
    task automatic measure_clk_period();
        realtime t0, t1;
        this.obi_mgr.cycle_end();
        t0 = $realtime;
        this.obi_mgr.cycle_end();
        t1 = $realtime;
        this.clk_period = (t1 - t0);
        if (this.clk_period <= 0) this.clk_period = 1ns;
    endtask

    function longint unsigned cycles_since(realtime t_then);
        if (this.clk_period <= 0) return 0;
        return longint'(($realtime - t_then) / this.clk_period);
    endfunction


    //==========================================================
    // Ring addressing helpers
    //   Top Log2MaxNodeIds bits of addr_t == destination node id.
    //   Lower bits == byte offset into the destination memory.
    //==========================================================
    function addr_t global_addr(int unsigned dst_id, addr_t local_off);
        addr_t a;
        a = '0;
        a[obi_mgr_drv_t::ObiCfg.AddrWidth-1 -: slink_reg_pkg::Log2MaxNodeIds] = dst_id[slink_reg_pkg::Log2MaxNodeIds-1:0];
        a[obi_mgr_drv_t::ObiCfg.AddrWidth-slink_reg_pkg::Log2MaxNodeIds-1:0]  = local_off[obi_mgr_drv_t::ObiCfg.AddrWidth-slink_reg_pkg::Log2MaxNodeIds-1:0];
        return a;
    endfunction

    function int unsigned dst_id_of(addr_t a);
        return int'(a[obi_mgr_drv_t::ObiCfg.AddrWidth-1 -: slink_reg_pkg::Log2MaxNodeIds]);
    endfunction


    //==========================================================
    // Register OBI bus
    //==========================================================
    task automatic cfg_write(cfg_addr_t addr, cfg_data_t wdata);
        cfg_data_t   rdata;
        id_t         rid;
        logic        err;
        r_optional_t r_opt;
        this.obi_reg.send_a(addr, 1'b1, '1, wdata, '0, '0);
        this.obi_reg.recv_r(rdata, rid, err, r_opt);
        if (err) print_error($sformatf("cfg_write: error response at 0x%08X", addr));
    endtask

    task automatic cfg_read(cfg_addr_t addr, output cfg_data_t data);
        id_t         rid;
        logic        err;
        r_optional_t r_opt;
        this.obi_reg.send_a(addr, 1'b0, '1, '0, '0, '0);
        this.obi_reg.recv_r(data, rid, err, r_opt);
        if (err) print_error($sformatf("cfg_read: error response at 0x%08X", addr));
    endtask


    //==========================================================
    // Bring-up
    //==========================================================
    // Reset drivers, wait for DUT reset deassertion, measure clk period, program NODE_ID.
    task automatic init();
        cfg_data_t data;
        this.obi_mgr.reset_manager();
        this.obi_reg.reset_manager();
        this.obi_sbr.reset_subordinate();
        this.obi_sbr.obi.err <= 1'b0; // Fix cause they do not implement it in the driver...

        wait (this.obi_mgr.obi.rst_ni === 1'b1);
        this.obi_mgr.cycle_end();
        measure_clk_period();

        cfg_write(`SLINK_REG_NODE_ID_REG_ADDR, cfg_data_t'(this.node_id));
        cfg_write(`SLINK_REG_CTRL_REG_ADDR, cfg_data_t'(0));
        repeat (8) this.obi_reg.cycle_end();
        cfg_read (`SLINK_REG_NODE_ID_REG_ADDR, data);
        if (data != cfg_data_t'(this.node_id))
            print_fatal($sformatf("NODE_ID read-back mismatch: wrote %0d read 0x%08X", this.node_id, data));
        print_info($sformatf("Initialized (clk_period = %0t)", this.clk_period));
    endtask


    // Apply optional PHY parameters. Pass 0 to skip a given knob.
    task automatic link_bringup(
        int unsigned tx_phy_clk_div   = 0,
        int unsigned tx_phy_clk_start = 0,
        int unsigned tx_phy_clk_end   = 0
    );
        if (tx_phy_clk_div   > 0)
            cfg_write(`SLINK_REG_TX_PHY_CLK_DIV_0_REG_ADDR,   cfg_data_t'(tx_phy_clk_div));
        if (tx_phy_clk_start > 0)
            cfg_write(`SLINK_REG_TX_PHY_CLK_START_0_REG_ADDR, cfg_data_t'(tx_phy_clk_start));
        if (tx_phy_clk_end   > 0)
            cfg_write(`SLINK_REG_TX_PHY_CLK_END_0_REG_ADDR,   cfg_data_t'(tx_phy_clk_end));
    endtask


    //==========================================================
    // Outstanding-transaction primitives (manager side)
    //==========================================================
    function bit can_issue();
        if (max_outstanding == 0) return 1'b1;
        return (this.pending.size() < max_outstanding);
    endfunction

    function int unsigned outstanding();
        return this.pending.size();
    endfunction


    // Issue an A beat without waiting for the matching R.
    // Blocks only if max_outstanding is reached.
    task automatic issue_a(input txn_desc_t desc, output txn_handle_t h);
        int payload_bytes;
        int effective_bytes;
        h.desc       = desc;
        h.aid        = this.aid_counter;
        h.full_addr  = global_addr(desc.dst_id, desc.local_addr);
        h.valid      = 1'b1;

        if (this.slot_sem != null) this.slot_sem.get(1);

        h.t_issue    = $realtime;
        this.obi_mgr.send_a(h.full_addr, desc.we, desc.be, desc.wdata, h.aid, desc.a_optional);
        h.t_granted  = $realtime;
        this.pending.push_back(h);
        this.aid_counter = id_t'(this.aid_counter + 1);

        payload_bytes = desc.we ? $countones(desc.be) : (obi_mgr_drv_t::ObiCfg.DataWidth/8);
        effective_bytes = (desc.we ? $bits(slink_obi_a_chan_write_t) : $bits(slink_obi_a_chan_read_t)) + 2*Log2MaxNodeIds + $bits(slink_pkg::tag_e);
        effective_bytes = (effective_bytes + 7) / 8;
        effective_bytes = effective_bytes * ((NumNodes + h.desc.dst_id - this.node_id) % NumNodes);
        if (this.monitor != null)
            this.monitor.on_a_issued(this.node_id, desc.tag, payload_bytes, effective_bytes);
    endtask


    // Wait for the next R beat, match it against pending[] by RID.
    task automatic recv_r(output txn_result_t res);
        id_t         rid;
        data_t       rdata;
        logic        err;
        r_optional_t r_opt;
        int          idx;
        int          effective_bytes;

        this.obi_mgr.recv_r(rdata, rid, err, r_opt);
        res.t_complete = $realtime;
        res.rid        = rid;
        res.rdata      = rdata;
        res.err        = err;
        res.r_optional = r_opt;

        idx = find_pending_by_aid(rid);
        if (idx < 0) begin
            print_error($sformatf("recv_r: unmatched RID 0x%0h", rid));
            return;
        end
        res.handle = this.pending[idx];
        this.pending.delete(idx);
        if (this.slot_sem != null) this.slot_sem.put(1);

        res.latency_time = res.t_complete - res.handle.t_issue;
        res.latency_cyc  = cycles_since(res.handle.t_issue);
        res.latency_time_from_granted = res.t_complete - res.handle.t_granted;
        res.latency_cyc_from_granted = cycles_since(res.handle.t_granted);

        effective_bytes = (res.handle.desc.we ? $bits(slink_obi_r_chan_write_t) : $bits(slink_obi_r_chan_read_t)) + 2*Log2MaxNodeIds + $bits(slink_pkg::tag_e);
        effective_bytes = (effective_bytes + 7) / 8;
        effective_bytes = effective_bytes * ((NumNodes + this.node_id - res.handle.desc.dst_id) % NumNodes);
        if (this.monitor != null)
            this.monitor.on_r_received(this.node_id, res.handle.desc.tag, res.latency_cyc, res.latency_cyc_from_granted, err, effective_bytes);

        if (res.handle.desc.expect_err && !err)
            print_error($sformatf("Expected error not seen for addr 0x%08X", res.handle.full_addr));
        if (!res.handle.desc.expect_err && err)
            print_error($sformatf("Unexpected error response for addr 0x%08X", res.handle.full_addr));
    endtask


    // Wait until all currently outstanding R have been received.
    task automatic drain();
        txn_result_t res;
        print_info($sformatf("Draining %0d outstanding transactions", this.pending.size()));
        while (this.pending.size() > 0) recv_r(res);
    endtask


    protected function int find_pending_by_aid(id_t rid);
        foreach (this.pending[i])
            if (this.pending[i].aid === rid) return i;
        return -1;
    endfunction


    //==========================================================
    // Subordinate memory accessors (called by TB inline RTL or run_sbr)
    //==========================================================
    function void mem_write_word(int unsigned byte_addr, data_t wdata, be_t be);
        int dw_bytes;
        dw_bytes = obi_mgr_drv_t::ObiCfg.DataWidth/8;
        for (int b = 0; b < dw_bytes; b++)
            if (be[b]) this.mem[(byte_addr + b) % MemSize] = wdata[b*8 +: 8];
    endfunction

    function data_t mem_read_word(int unsigned byte_addr);
        data_t r;
        int dw_bytes;
        r = '0;
        dw_bytes = obi_mgr_drv_t::ObiCfg.DataWidth/8;
        for (int b = 0; b < dw_bytes; b++)
            r[b*8 +: 8] = this.mem[(byte_addr + b) % MemSize];
        return r;
    endfunction

    function void expected_write_word(int unsigned byte_addr, data_t wdata, be_t be);
        int dw_bytes;
        dw_bytes = obi_mgr_drv_t::ObiCfg.DataWidth/8;
        for (int b = 0; b < dw_bytes; b++)
            if (be[b]) this.expected_mem[(byte_addr + b) % MemSize] = wdata[b*8 +: 8];
    endfunction

    function data_t expected_read_word(int unsigned byte_addr);
        data_t r;
        int dw_bytes;
        r = '0;
        dw_bytes = obi_mgr_drv_t::ObiCfg.DataWidth/8;
        for (int b = 0; b < dw_bytes; b++)
            r[b*8 +: 8] = this.expected_mem[(byte_addr + b) % MemSize];
        return r;
    endfunction


    //==========================================================
    // Run-forever subordinate using the obi_sbr driver.
    //==========================================================
    task automatic run_sbr();
        addr_t        a_addr;
        logic         a_we;
        be_t          a_be;
        data_t        a_wdata;
        id_t          a_aid;
        a_optional_t  a_opt;
        data_t        rdata;
        int unsigned  local_byte;
        forever begin
            this.obi_sbr.recv_a(a_addr, a_we, a_be, a_wdata, a_aid, a_opt);
            local_byte = int'(a_addr);
            if (local_byte < MemSize) begin
                if (a_we) begin
                    mem_write_word(local_byte, a_wdata, a_be);
                    rdata = '0;
                end else begin
                    rdata = mem_read_word(local_byte);
                end
                this.obi_sbr.obi.err <= 1'b0;
            end else begin
                this.obi_sbr.obi.err <= 1'b1;
                rdata = '0;
            end
            this.obi_sbr.send_r(rdata, a_aid, '0);
        end
    endtask

endclass

`endif // NODE_SVH
