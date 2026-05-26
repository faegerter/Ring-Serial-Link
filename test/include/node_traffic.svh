// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Author: Llorenç Muela Hausmann <lmuela@ethz.ch>
// Author: Fabian Aegerter <faegerter@ethz.ch>
//
// NodeTraffic: parameterized class of static helper methods that compose
// the Node primitives (issue_a / recv_r / drain) into common traffic
// patterns. Testbenches that need finer control bypass these helpers
// and call the Node primitives directly.

`ifndef NODE_TRAFFIC_SVH
`define NODE_TRAFFIC_SVH

`include "node.svh"

class NodeTraffic #(type node_t);

    typedef node_t::txn_desc_t   txn_desc_t;
    typedef node_t::txn_handle_t txn_handle_t;
    typedef node_t::txn_result_t txn_result_t;
    typedef node_t::data_t       data_t;
    typedef node_t::addr_t       addr_t;
    typedef node_t::be_t         be_t;


    //----------------------------------------------------------
    // Descriptor builders
    //----------------------------------------------------------
    static function txn_desc_t make_write(
        int unsigned dst_id,
        addr_t       local_addr,
        data_t       wdata,
        be_t         be          = '1,
        int          tag         = node_t::TAG_REMOTE_W,
        logic        expect_err  = 1'b0
    );
        txn_desc_t d;
        d.dst_id     = dst_id;
        d.local_addr = local_addr;
        d.we         = 1'b1;
        d.be         = be;
        d.wdata      = wdata;
        d.a_optional = '0;
        d.tag        = tag;
        d.expect_err = expect_err;
        return d;
    endfunction

    static function txn_desc_t make_read(
        int unsigned dst_id,
        addr_t       local_addr,
        be_t         be          = '1,
        int          tag         = node_t::TAG_REMOTE_R,
        logic        expect_err  = 1'b0
    );
        txn_desc_t d;
        d.dst_id     = dst_id;
        d.local_addr = local_addr;
        d.we         = 1'b0;
        d.be         = be;
        d.wdata      = '0;
        d.a_optional = '0;
        d.tag        = tag;
        d.expect_err = expect_err;
        return d;
    endfunction


    //----------------------------------------------------------
    // Pipelined burst of n word-sized writes from src to dst.
    // Updates dst.expected_mem so a later read-back can verify.
    //----------------------------------------------------------
    static task automatic burst_writes(
        node_t       src,
        node_t       dst,
        int unsigned n,
        int unsigned base_offset = 0,
        int          tag         = node_t::TAG_REMOTE_W,
        bit          rnd_data    = 1'b1,
        data_t       data        = '0
    );
        int unsigned dw_bytes;
        dw_bytes = $bits(data_t) / 8;

        fork
            begin : sender
                int unsigned i;
                for (i = 0; i < n; i++) begin
                    automatic addr_t       loc;
                    automatic data_t       v;
                    automatic txn_desc_t   d;
                    automatic txn_handle_t h;
                    loc = addr_t'(base_offset + i * dw_bytes);
                    if (rnd_data) v   = data_t'($urandom());
                    else v = data;
                    d   = make_write(dst.node_id, loc, v, '1, tag);
                    if (dst != null) dst.expected_write_word(int'(loc), v, '1);
                    src.issue_a(d, h);
                end
            end
            begin : receiver
                int unsigned i;
                for (i = 0; i < n; i++) begin
                    automatic txn_result_t r;
                    src.recv_r(r);
                end
            end
        join
    endtask


    //----------------------------------------------------------
    // Pipelined read-back. Compares against dst.expected_mem and
    // returns the mismatch count.
    //----------------------------------------------------------
    static task automatic burst_read_back(
        node_t       src,
        node_t       dst,
        int unsigned n,
        output int unsigned mismatches,
        input int unsigned base_offset = 0,
        input int          tag         = node_t::TAG_REMOTE_R
    );
        int unsigned dw_bytes;
        int unsigned mm;
        dw_bytes = $bits(data_t) / 8;
        mm = 0;

        fork
            begin : sender
                int unsigned i;
                for (i = 0; i < n; i++) begin
                    automatic addr_t       loc;
                    automatic txn_desc_t   d;
                    automatic txn_handle_t h;
                    loc = addr_t'(base_offset + i * dw_bytes);
                    d   = make_read(dst.node_id, loc, '1, tag);
                    src.issue_a(d, h);
                end
            end
            begin : receiver
                int unsigned i;
                for (i = 0; i < n; i++) begin
                    automatic txn_result_t r;
                    automatic data_t       exp_w;
                    src.recv_r(r);
                    exp_w = dst.expected_read_word(int'(r.handle.desc.local_addr));
                    if (r.rdata !== exp_w) begin
                        mm++;
                        src.print_error($sformatf(
                            "read-back mismatch at dst=%0d off=0x%0h: got 0x%08X expected 0x%08X",
                            dst.node_id, r.handle.desc.local_addr, r.rdata, exp_w));
                    end
                end
            end
        join

        mismatches = mm;
    endtask


    //----------------------------------------------------------
    // Saturated reads: issue n_txns reads back-to-back at maximum
    // outstanding pressure. Useful for throughput plots; the global
    // SlinkPerfMonitor will record per-tag latency / payload bytes.
    //----------------------------------------------------------
    static task automatic saturate_reads(
        node_t       src,
        int unsigned dst_id,
        int unsigned n_txns,
        int          tag         = node_t::TAG_REMOTE_R,
        int unsigned base_offset = 0,
        int unsigned addr_window = 16
    );
        int unsigned dw_bytes;
        dw_bytes = $bits(data_t) / 8;

        fork
            begin : sender
                int unsigned i;
                for (i = 0; i < n_txns; i++) begin
                    automatic addr_t       loc;
                    automatic txn_desc_t   d;
                    automatic txn_handle_t h;
                    loc = addr_t'(base_offset + (i % addr_window) * dw_bytes);
                    d   = make_read(dst_id, loc, '1, tag);
                    src.issue_a(d, h);
                end
            end
            begin : receiver
                int unsigned i;
                for (i = 0; i < n_txns; i++) begin
                    automatic txn_result_t r;
                    src.recv_r(r);
                end
            end
        join
    endtask


    //----------------------------------------------------------
    // Programmable mixed traffic: every issued txn is built by the
    // caller via `make_*`. The caller queues them into `descs`; this
    // task pipelines issue / collect with optional outstanding cap.
    //----------------------------------------------------------
    static task automatic run_descs(
        node_t              src,
        txn_desc_t    descs [$]
    );
        int unsigned n;
        n = descs.size();
        fork
            begin : sender
                int unsigned i;
                for (i = 0; i < n; i++) begin
                    automatic txn_handle_t h;
                    src.issue_a(descs[i], h);
                end
            end
            begin : receiver
                int unsigned i;
                for (i = 0; i < n; i++) begin
                    automatic txn_result_t r;
                    src.recv_r(r);
                end
            end
        join
    endtask

endclass

`endif // NODE_TRAFFIC_SVH
