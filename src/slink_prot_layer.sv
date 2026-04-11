// Copyright 2022 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Author: Tim Fischer <fischeti@iis.ee.ethz.ch>
// Author: Llorenç Muela Hausmann <lmuela@ethz.ch>
// Author: Fabian Aegerter <faegerter@ethz.ch>

`include "common_cells/registers.svh"
`include "common_cells/assertions.svh"



`define INCR_WRAP(num_q, MAX) ((num_q == MAX-1) ? 0 : num_q + 1)


module slink_prot_layer #(
    parameter type obi_req_t  = logic,
    parameter type obi_rsp_t  = logic,
    parameter type a_optional_t  = logic,
    parameter type r_optional_t  = logic,
    parameter type axis_req_t = logic,
    parameter type axis_rsp_t = logic,
    parameter type a_chan_write_t   = logic,
    parameter type a_chan_read_t    = logic,
    parameter type r_chan_write_t   = logic,
    parameter type r_chan_read_t    = logic,
    parameter type payload_t  = logic,
    parameter slink_pkg::slink_obi_cfg_t slink_obi_cfg,
    parameter type credit_t = logic,
    parameter int PayloadSplits = 1
) (
    input  logic      clk_i,
    input  logic      rst_ni,
    input  logic[3:0] node_id_i,
    input  obi_req_t  obi_in_req_i,
    output obi_rsp_t  obi_in_rsp_o,
    output obi_req_t  obi_out_req_o,
    input  obi_rsp_t  obi_out_rsp_i,
    output axis_req_t axis_out_req_o,
    input  axis_rsp_t axis_out_rsp_i,
    input  axis_req_t axis_in_req_i,
    output axis_rsp_t axis_in_rsp_o,
    input  credit_t   credits_out_i 
);

    typedef logic [slink_obi_cfg.IDWidth-1:0] obi_id_t;
    typedef logic [slink_obi_cfg.DataWidth-1:0] obi_data_t;
    typedef logic [slink_obi_cfg.DataWidth/8-1:0] obi_be_t;


    function automatic obi_rsp_t obi_rsp_pack(logic rvalid, obi_data_t rdata, obi_id_t rid, logic err, r_optional_t r_optional);
        return '{
            rvalid: rvalid,
            gnt: 1'b0,
            r: '{
                rdata: rdata,
                rid: rid,
                err: err,
                r_optional: r_optional
            }
        };
    endfunction

    function automatic payload_t make_r_payload(input logic is_write,
                                                input logic [3:0] src_id,
                                                input logic [3:0] dst_id,
                                                input r_chan_write_t rwr,
                                                input r_chan_read_t  rrd);
        payload_t ret;
        ret        = '0;
        ret.hdr    = is_write ? slink_pkg::TagRWrite : slink_pkg::TagRRead;
        ret.src_id = src_id;
        ret.dst_id = dst_id;
        ret.obi_ch = is_write ? rwr : rrd;
        return ret;
    endfunction

    function automatic payload_t make_a_payload(input logic is_write,
                                                input logic [3:0] src_id,
                                                input logic [3:0] dst_id,
                                                input a_chan_write_t awr,
                                                input a_chan_read_t  ard);
        payload_t ret;
        ret        = '0;
        ret.hdr    = is_write ? slink_pkg::TagAWrite : slink_pkg::TagARead;
        ret.src_id = src_id;
        ret.dst_id = dst_id;
        ret.obi_ch = is_write ? awr : ard;
        return ret;
    endfunction


    localparam int TX_FIFO_DEPTH = 3;
    localparam int MAX_OUTSTANDING_OUT = 2;


    logic rr_tx_out_arb_q, rr_tx_out_arb_d;
    payload_t payload_out, payload_in;


    logic tx_fifo_valid_out, tx_fifo_ready_out;
    logic tx_fifo_valid_in, tx_fifo_ready_in;
    payload_t tx_fifo_data_in, tx_fifo_data_out;
    logic[1:0] tx_fifo_fill_state;

    typedef struct packed {
        logic [3:0] src_id;
        logic is_write;
    } issued_reqs_data_t;


    typedef struct packed {
        logic           valid;
        slink_pkg::tx_e tx_type;
        obi_id_t        aid;
    } tx_cmd_t;

    tx_cmd_t tx_cmd;

    logic [3:0] addr_to_node_id;

    issued_reqs_data_t issued_reqs_fifo_data_in;
    issued_reqs_data_t issued_reqs_fifo_data_out;
    logic[1:0] issued_reqs_fifo_fill_state;
    logic issued_reqs_fifo_pop;
    logic issued_reqs_fifo_push;
    logic issued_reqs_fifo_full;
    logic issued_reqs_fifo_empty;


    assign addr_to_node_id = obi_in_req_i.a.addr[slink_obi_cfg.AddrWidth-1 -: 4];



    fifo_v3 #(
        .DEPTH  ( 2           ),
        .dtype  ( issued_reqs_data_t  )
    ) i_issued_reqs_fifo (
        .clk_i      ( clk_i               ),
        .rst_ni     ( rst_ni              ),
        .flush_i    ( 1'b0                ),
        .testmode_i ( 1'b0                ),
        .full_o     ( issued_reqs_fifo_full ),
        .empty_o    ( issued_reqs_fifo_empty ),
        .usage_o    ( issued_reqs_fifo_fill_state ),
        .data_i     ( issued_reqs_fifo_data_in ),
        .push_i     ( issued_reqs_fifo_push ),
        .data_o     ( issued_reqs_fifo_data_out ),
        .pop_i      ( issued_reqs_fifo_pop )
    );

    logic [$clog2(MAX_OUTSTANDING_OUT):0] rsp_reorder_idx_head_q, rsp_reorder_idx_head_d;
    logic [$clog2(MAX_OUTSTANDING_OUT):0] rsp_reorder_idx_tail_q, rsp_reorder_idx_tail_d;

    `FF(rsp_reorder_idx_head_q, rsp_reorder_idx_head_d, '0);
    `FF(rsp_reorder_idx_tail_q, rsp_reorder_idx_tail_d, '0);

    obi_rsp_t [MAX_OUTSTANDING_OUT-1:0] rsp_reorder_in_data, rsp_reorder_out_data;
    logic [MAX_OUTSTANDING_OUT-1:0] rsp_reorder_in_valid, rsp_reorder_out_valid;
    logic [MAX_OUTSTANDING_OUT-1:0] rsp_reorder_in_ready, rsp_reorder_out_ready;
    
    obi_id_t [MAX_OUTSTANDING_OUT-1:0] rsp_reorder_ids_q, rsp_reorder_ids_d;
    logic [MAX_OUTSTANDING_OUT-1:0] rsp_reorder_idx_pending_q, rsp_reorder_idx_pending_d;

    `FF(rsp_reorder_ids_q, rsp_reorder_ids_d, '0);
    `FF(rsp_reorder_idx_pending_q, rsp_reorder_idx_pending_d, '0);

    for (genvar i = 0; i < MAX_OUTSTANDING_OUT; i++) begin : gen_reorder_rsp_buffers
        stream_register #(
            .T (obi_rsp_t)
        ) i_recv_reg (
            .clk_i      ( clk_i                       ),
            .rst_ni     ( rst_ni                      ),
            .clr_i      ( 1'b0                        ),
            .testmode_i ( 1'b0                        ),
            .valid_i    ( rsp_reorder_in_valid[i]     ),
            .ready_o    ( rsp_reorder_in_ready[i]     ),
            .data_i     ( rsp_reorder_in_data[i]      ),
            .valid_o    ( rsp_reorder_out_valid[i]    ),
            .ready_i    ( rsp_reorder_out_ready[i]    ),
            .data_o     ( rsp_reorder_out_data[i]     )
        );
    end


    logic [1:0] reserved_for_local_rsp_cnt;


    assign reserved_for_local_rsp_cnt = obi_out_req_o.req ? issued_reqs_fifo_fill_state + 1 : issued_reqs_fifo_fill_state;


    logic can_enqueue_response, can_enqueue_tx;

    assign can_enqueue_response = ((TX_FIFO_DEPTH - tx_fifo_fill_state) > issued_reqs_fifo_fill_state) && !issued_reqs_fifo_full;

    assign can_enqueue_tx = ((TX_FIFO_DEPTH - tx_fifo_fill_state) > reserved_for_local_rsp_cnt);


    r_chan_write_t r_chan_write_out;
    r_chan_read_t r_chan_read_out;
    a_chan_write_t a_chan_write_out;
    a_chan_read_t a_chan_read_out;

    a_chan_write_t a_chan_write_loc;
    a_chan_read_t  a_chan_read_loc;


    r_chan_write_t r_chan_write_in;
    r_chan_read_t r_chan_read_in;
    a_chan_write_t a_chan_write_in;
    a_chan_read_t a_chan_read_in;


    assign r_chan_write_out.rid = obi_out_rsp_i.r.rid;
    assign r_chan_write_out.err = obi_out_rsp_i.r.err;

    assign r_chan_read_out.rid = obi_out_rsp_i.r.rid;
    assign r_chan_read_out.err = obi_out_rsp_i.r.err;
    assign r_chan_read_out.rdata = obi_out_rsp_i.r.rdata;

    assign a_chan_write_out.addr = {4'b0, obi_in_req_i.a.addr[slink_obi_cfg.AddrWidth-5:0]};
    // assign a_chan_write_out.aid = obi_in_req_i.a.aid;
    assign a_chan_write_out.aid = rsp_reorder_idx_tail_q;
    assign a_chan_write_out.wdata = obi_in_req_i.a.wdata;

    assign a_chan_read_out.addr = {4'b0, obi_in_req_i.a.addr[slink_obi_cfg.AddrWidth-5:0]};
    // assign a_chan_read_out.aid = obi_in_req_i.a.aid;
    assign a_chan_read_out.aid = rsp_reorder_idx_tail_q;


    a_optional_t a_chan_read_optional_in;
    a_optional_t a_chan_write_optional_in;
    r_optional_t r_chan_read_optional_in;
    r_optional_t r_chan_write_optional_in;
    obi_be_t a_chan_read_be_in;
    obi_be_t a_chan_write_be_in;


    assign r_chan_read_in  = r_chan_read_t'(payload_in.obi_ch);
    assign r_chan_write_in = r_chan_write_t'(payload_in.obi_ch);
    assign a_chan_read_in  = a_chan_read_t'(payload_in.obi_ch);
    assign a_chan_write_in = a_chan_write_t'(payload_in.obi_ch);


    if (slink_obi_cfg.UseOptional) begin
        assign r_chan_write_out.r_optional = obi_out_rsp_i.r.r_optional;
        assign r_chan_read_out.r_optional = obi_out_rsp_i.r.r_optional;
        assign a_chan_write_out.a_optional = obi_in_req_i.a.a_optional;
        assign a_chan_read_out.a_optional = obi_in_req_i.a.a_optional;

        assign a_chan_read_optional_in = a_chan_read_in.a_optional;
        assign a_chan_write_optional_in = a_chan_write_in.a_optional;
        assign r_chan_read_optional_in = r_chan_read_in.r_optional;
        assign r_chan_write_optional_in = r_chan_write_in.r_optional;

    end else begin
        assign a_chan_read_optional_in = '0;
        assign a_chan_write_optional_in = '0;
        assign r_chan_read_optional_in = '0;
        assign r_chan_write_optional_in = '0;
    end

    if (slink_obi_cfg.UseByteEnable) begin
        assign a_chan_read_be_in = a_chan_read_in.be;
        assign a_chan_write_be_in = a_chan_write_in.be;
        assign a_chan_write_out.be = obi_in_req_i.a.be;
        assign a_chan_read_out.be = obi_in_req_i.a.be;

    end else begin
        assign a_chan_read_be_in = '1;
        assign a_chan_write_be_in = '1;
    end


    slink_pkg::rx_e rx_type;

    always_comb begin : tx_fifo_in_arbiter

        tx_cmd = '0;
        payload_out = '0;
        rr_tx_out_arb_d = rr_tx_out_arb_q;

        if (obi_out_rsp_i.rvalid && !issued_reqs_fifo_empty) begin
            // rsp out always prioritized
            payload_out = make_r_payload(
                issued_reqs_fifo_data_out.is_write,
                node_id_i,
                issued_reqs_fifo_data_out.src_id,
                r_chan_write_out,
                r_chan_read_out
            );

            tx_cmd.tx_type = slink_pkg::TxOutgoingR;
            tx_cmd.valid = 1'b1;

        end else if (can_enqueue_tx) begin
            // Round Robin arbiter between req out and transit
            unique case ({obi_in_req_i.req && ~&rsp_reorder_idx_pending_q, rx_type == slink_pkg::RxTransit})
                2'b01: begin
                    // No request and transit
                    payload_out  = payload_in;
                    tx_cmd.tx_type = slink_pkg::TxTransit;
                    tx_cmd.valid = 1'b1;
                    rr_tx_out_arb_d = 1'b0;
                end
                2'b10: begin
                    // Request and no transit
                    a_chan_write_loc = a_chan_write_out;
                    a_chan_read_loc  = a_chan_read_out;
                    if (addr_to_node_id == node_id_i) begin
                        a_chan_write_loc.addr[slink_obi_cfg.AddrWidth-1 -: 4] = '0;
                        a_chan_read_loc.addr[slink_obi_cfg.AddrWidth-1 -: 4]  = '0;
                    end
                    payload_out = make_a_payload(obi_in_req_i.a.we, node_id_i, addr_to_node_id, a_chan_write_loc, a_chan_read_loc);

                    tx_cmd.aid = obi_in_req_i.a.aid;
                    tx_cmd.valid = 1'b1;
                    tx_cmd.tx_type = slink_pkg::TxOutgoingA;

                    rr_tx_out_arb_d = 1'b1;
                end
                2'b11: begin
                    // Request and transit
                    if (rr_tx_out_arb_q) begin
                        payload_out  = payload_in;
                        tx_cmd.tx_type = slink_pkg::TxTransit;
                        tx_cmd.valid = 1'b1;

                    end else begin
                        
                        a_chan_write_loc = a_chan_write_out;
                        a_chan_read_loc  = a_chan_read_out;

                        if (addr_to_node_id == node_id_i) begin
                            a_chan_write_loc.addr[slink_obi_cfg.AddrWidth-1 -: 4] = '0;
                            a_chan_read_loc.addr[slink_obi_cfg.AddrWidth-1 -: 4]  = '0;
                        end

                        payload_out = make_a_payload(obi_in_req_i.a.we, node_id_i, addr_to_node_id, a_chan_write_loc, a_chan_read_loc);

                        tx_cmd.aid = obi_in_req_i.a.aid;
                        tx_cmd.valid = 1'b1;

                        tx_cmd.tx_type = slink_pkg::TxOutgoingA;
                    end
                    rr_tx_out_arb_d = ~rr_tx_out_arb_q;
                end
                default: begin
                    // No request and no transit
                end
            endcase
        end
    end


    always_comb begin : rx_redirector

        rx_type = slink_pkg::RxNone;

        if (axis_in_req_i.tvalid) begin
            if (payload_in.src_id == node_id_i) begin
                rx_type = slink_pkg::RxLoop;
            end else if (payload_in.dst_id == node_id_i) begin
                unique case (payload_in.hdr)
                    slink_pkg::TagARead:  rx_type = slink_pkg::RxIncomingARead;
                    slink_pkg::TagAWrite: rx_type = slink_pkg::RxIncomingAWrite;
                    slink_pkg::TagRRead:  rx_type = slink_pkg::RxIncomingRRead;
                    slink_pkg::TagRWrite: rx_type = slink_pkg::RxIncomingRWrite;
                    default:         rx_type = slink_pkg::RxError;
                endcase
            // TODO enforce loop must be a correct payload since we need to read ID
            end else if (payload_in.src_id == node_id_i) begin
                rx_type = slink_pkg::RxLoop;
            end else if (payload_in.hdr == slink_pkg::TagARead || payload_in.hdr == slink_pkg::TagAWrite || payload_in.hdr == slink_pkg::TagRRead || payload_in.hdr == slink_pkg::TagRWrite) begin
                rx_type = slink_pkg::RxTransit;
            end else begin
                rx_type = slink_pkg::RxError;
            end
        end
    end


    always_comb begin : commiter

        obi_in_rsp_o = '0;
        obi_out_req_o = '0;

        tx_fifo_valid_in = 1'b0;
        issued_reqs_fifo_pop = 1'b0;
        issued_reqs_fifo_push = 1'b0;
        axis_in_rsp_o.tready = 1'b0;

        rsp_reorder_idx_head_d = rsp_reorder_idx_head_q;
        rsp_reorder_idx_tail_d = rsp_reorder_idx_tail_q;
        rsp_reorder_ids_d = rsp_reorder_ids_q;
        rsp_reorder_idx_pending_d = rsp_reorder_idx_pending_q;

        rsp_reorder_in_valid  = '0;
        rsp_reorder_in_data   = '0;
        rsp_reorder_out_ready = '0;

        if (rx_type == slink_pkg::RxIncomingRRead && r_chan_read_in.rid == rsp_reorder_idx_head_d) begin 
            axis_in_rsp_o.tready = 1'b1;
            obi_in_rsp_o = obi_rsp_pack(1'b1, r_chan_read_in.rdata, rsp_reorder_ids_q[r_chan_read_in.rid], r_chan_read_in.err, r_chan_read_optional_in);
            rsp_reorder_idx_head_d = `INCR_WRAP(rsp_reorder_idx_head_d, MAX_OUTSTANDING_OUT);
            rsp_reorder_idx_pending_d[rsp_reorder_idx_head_d] = 1'b0;

        end else if(rx_type == slink_pkg::RxIncomingRWrite && r_chan_write_in.rid == rsp_reorder_idx_head_d) begin 
            axis_in_rsp_o.tready = 1'b1;
            obi_in_rsp_o = obi_rsp_pack(1'b1, '0, rsp_reorder_ids_q[r_chan_write_in.rid], r_chan_write_in.err, r_chan_write_optional_in);
            rsp_reorder_idx_head_d = `INCR_WRAP(rsp_reorder_idx_head_q, MAX_OUTSTANDING_OUT);
            rsp_reorder_idx_pending_d[rsp_reorder_idx_head_q] = 1'b0;

        end else begin if (rx_type == slink_pkg::RxIncomingRRead && rsp_reorder_in_ready[r_chan_read_in.rid]) begin
                axis_in_rsp_o.tready = 1'b1;
                rsp_reorder_in_valid[r_chan_read_in.rid] = 1'b1;
                rsp_reorder_in_data[r_chan_read_in.rid] = obi_rsp_pack(1'b1, r_chan_read_in.rdata, rsp_reorder_ids_q[r_chan_read_in.rid], r_chan_read_in.err, r_chan_read_optional_in);

            end
            if (rx_type == slink_pkg::RxIncomingRWrite && rsp_reorder_in_ready[r_chan_write_in.rid]) begin
                axis_in_rsp_o.tready = 1'b1;
                rsp_reorder_in_valid[r_chan_write_in.rid] = 1'b1;
                rsp_reorder_in_data[r_chan_write_in.rid] = obi_rsp_pack(1'b1, '0, rsp_reorder_ids_q[r_chan_write_in.rid], r_chan_write_in.err, r_chan_write_optional_in);
            end
        end

        if (rx_type == slink_pkg::RxLoop) begin
            if (payload_in.hdr == slink_pkg::TagRRead) begin
                // R channel loop means answer to remote request could not be delivered. We can do nothing else than drop it. TODO should send error or something.
                axis_in_rsp_o.tready = 1'b1; // Consume and discard

            end else if (payload_in.hdr == slink_pkg::TagRWrite) begin
                // R channel loop means answer to remote request could not be delivered. We can do nothing else than drop it. TODO should send error or something.
                axis_in_rsp_o.tready = 1'b1; // Consume and discard

            end else if (payload_in.hdr == slink_pkg::TagARead && rsp_reorder_in_ready[a_chan_read_in.aid]) begin
                axis_in_rsp_o.tready = 1'b1; // Consume and error
                rsp_reorder_in_valid[a_chan_read_in.aid] = 1'b1;
                rsp_reorder_in_data [a_chan_read_in.aid] = obi_rsp_pack(1'b1, '0, rsp_reorder_ids_q[a_chan_read_in.aid], 1'b1, '0);

            end else if (payload_in.hdr == slink_pkg::TagAWrite && rsp_reorder_in_ready[a_chan_write_in.aid]) begin
                axis_in_rsp_o.tready = 1'b1; // Consume and error
                rsp_reorder_in_valid[a_chan_write_in.aid] = 1'b1;
                rsp_reorder_in_data [a_chan_write_in.aid] = obi_rsp_pack(1'b1, '0, rsp_reorder_ids_q[a_chan_write_in.aid], 1'b1, '0);

            end
        end


        if (rsp_reorder_out_valid[rsp_reorder_idx_head_q]) begin
            obi_in_rsp_o = rsp_reorder_out_data[rsp_reorder_idx_head_q];
            rsp_reorder_out_ready[rsp_reorder_idx_head_q] = 1'b1;
            rsp_reorder_idx_head_d = `INCR_WRAP(rsp_reorder_idx_head_q, MAX_OUTSTANDING_OUT);
            rsp_reorder_idx_pending_d[rsp_reorder_idx_head_q] = 1'b0;
        end


        if (rx_type == slink_pkg::RxError) begin
            axis_in_rsp_o.tready = 1'b1; // Consume and discard (not a payload, should never happen)
        end

        if (rx_type == slink_pkg::RxIncomingARead && can_enqueue_response) begin
            obi_out_req_o.req = 1'b1;

            obi_out_req_o.a.addr = a_chan_read_in.addr;
            obi_out_req_o.a.aid = a_chan_read_in.aid;
            obi_out_req_o.a.wdata = '0;
            obi_out_req_o.a.we = 1'b0;
            obi_out_req_o.a.a_optional = a_chan_read_optional_in;
            obi_out_req_o.a.be = a_chan_read_be_in;

            if (obi_out_rsp_i.gnt) begin
                issued_reqs_fifo_push    = 1'b1;
                axis_in_rsp_o.tready     = 1'b1;
            end
        end

        if (rx_type == slink_pkg::RxIncomingAWrite && can_enqueue_response) begin
            obi_out_req_o.req = 1'b1;

            obi_out_req_o.a.addr = a_chan_write_in.addr;
            obi_out_req_o.a.aid = a_chan_write_in.aid;
            obi_out_req_o.a.wdata = a_chan_write_in.wdata;
            obi_out_req_o.a.we = 1'b1;
            obi_out_req_o.a.a_optional = a_chan_write_optional_in;
            obi_out_req_o.a.be = a_chan_write_be_in;

            if (obi_out_rsp_i.gnt) begin
                issued_reqs_fifo_push    = 1'b1;
                axis_in_rsp_o.tready     = 1'b1;
            end
        end

        if (tx_cmd.tx_type == slink_pkg::TxSelfReq && tx_cmd.valid && rsp_reorder_in_ready[rsp_reorder_idx_tail_q] && rx_type != slink_pkg::RxLoop && rx_type != slink_pkg::RxIncomingRRead && rx_type != slink_pkg::RxIncomingRWrite) begin
            obi_in_rsp_o.gnt = 1'b1;
            rsp_reorder_in_valid[rsp_reorder_idx_tail_q] = 1'b1;
            rsp_reorder_in_data [rsp_reorder_idx_tail_q] = obi_rsp_pack(1'b1, '0, tx_cmd.aid, 1'b1, '0);

            rsp_reorder_idx_tail_d = `INCR_WRAP(rsp_reorder_idx_tail_q, MAX_OUTSTANDING_OUT);
            rsp_reorder_idx_pending_d[rsp_reorder_idx_tail_q] = 1'b1;
        end

        if (tx_fifo_ready_in && tx_cmd.valid) begin
            if (tx_cmd.tx_type == slink_pkg::TxOutgoingR) begin
                tx_fifo_valid_in = 1'b1;
                issued_reqs_fifo_pop = 1'b1;

            end else if (tx_cmd.tx_type == slink_pkg::TxOutgoingA) begin
                tx_fifo_valid_in = 1'b1;
                obi_in_rsp_o.gnt = 1'b1; // TODO this is fragile because depends on order when obi_in_rsp_o = rsp_reorder_out_data[rsp_reorder_idx_head_q] also entered
                rsp_reorder_ids_d[rsp_reorder_idx_tail_q] = tx_cmd.aid;
                rsp_reorder_idx_tail_d = `INCR_WRAP(rsp_reorder_idx_tail_q, MAX_OUTSTANDING_OUT);
                rsp_reorder_idx_pending_d[rsp_reorder_idx_tail_q] = 1'b1;

            end else if (tx_cmd.tx_type == slink_pkg::TxTransit) begin
                tx_fifo_valid_in = 1'b1;
                axis_in_rsp_o.tready = 1'b1;

            end
        end
    end


    assign tx_fifo_data_in = payload_out;
    assign axis_out_req_o.tvalid = tx_fifo_valid_out;
    assign axis_out_req_o.t.data = tx_fifo_data_out;
    assign tx_fifo_ready_out = axis_out_rsp_i.tready;

    assign issued_reqs_fifo_data_in = {
        payload_in.src_id,
        payload_in.hdr == slink_pkg::TagAWrite
    };

    stream_fifo #(
        .DEPTH  ( 3           ),
        .T      (  payload_t  )
    ) i_axis_out_reg (
        .clk_i      ( clk_i               ),
        .rst_ni     ( rst_ni              ),
        .flush_i    ( 1'b0                ),
        .testmode_i ( 1'b0                ),
        .usage_o    ( tx_fifo_fill_state ),
        .valid_i    ( tx_fifo_valid_in   ),
        .ready_o    ( tx_fifo_ready_in   ),
        .data_i     ( tx_fifo_data_in    ),
        .valid_o    ( tx_fifo_valid_out  ),
        .ready_i    ( tx_fifo_ready_out  ),
        .data_o     ( tx_fifo_data_out   )
    );

    assign payload_in = payload_t'(axis_in_req_i.t.data);


    `FF(rr_tx_out_arb_q, rr_tx_out_arb_d, '0);



    ////////////////////
    //   ASSERTIONS   //
    ////////////////////
    
    `ASSERT(AxisStable, axis_out_req_o.tvalid & !axis_out_rsp_i.tready |=> $stable(axis_out_req_o.t))
    `ASSERT(AxisHandshake, axis_out_req_o.tvalid & !axis_out_rsp_i.tready |=> axis_out_req_o.tvalid)
endmodule
