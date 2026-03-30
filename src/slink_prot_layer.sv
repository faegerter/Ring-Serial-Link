// Copyright 2022 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Author: Tim Fischer <fischeti@iis.ee.ethz.ch>
// Author: Llorenç Muela Hausmann <lmuela@ethz.ch>
// Author: Fabian Aegerter <faegerter@ethz.ch>

`include "common_cells/registers.svh"
`include "common_cells/assertions.svh"



module slink_prot_layer #(
    parameter type obi_req_t  = logic,
    parameter type obi_rsp_t  = logic,
    parameter type a_optional_t  = logic,
    parameter type r_optional_t  = logic,
    parameter type axis_req_t = logic,
    parameter type axis_rsp_t = logic,
    // parameter type a_chan_t   = logic,
    // parameter type r_chan_t   = logic,
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

    localparam int TX_FIFO_DEPTH = 3;


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


    issued_reqs_data_t issued_reqs_fifo_data_in;
    issued_reqs_data_t issued_reqs_fifo_data_out;
    logic[1:0] issued_reqs_fifo_fill_state;
    logic issued_reqs_fifo_pop;
    logic issued_reqs_fifo_push;
    logic issued_reqs_fifo_full;
    logic issued_reqs_fifo_empty;



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


    logic [1:0] reserved_for_local_rsp_cnt;


    assign reserved_for_local_rsp_cnt = obi_out_req_o.req ? issued_reqs_fifo_fill_state + 1 : issued_reqs_fifo_fill_state;


    logic can_enqueue_response, can_enqueue_tx;

    assign can_enqueue_response = ((TX_FIFO_DEPTH - tx_fifo_fill_state) > issued_reqs_fifo_fill_state) && !issued_reqs_fifo_full;

    assign can_enqueue_tx = ((TX_FIFO_DEPTH - tx_fifo_fill_state) > reserved_for_local_rsp_cnt);


    r_chan_write_t r_chan_write_out;
    r_chan_read_t r_chan_read_out;
    a_chan_write_t a_chan_write_out;
    a_chan_read_t a_chan_read_out;

    r_chan_write_t r_chan_write_in;
    r_chan_read_t r_chan_read_in;
    a_chan_write_t a_chan_write_in;
    a_chan_read_t a_chan_read_in;


    assign r_chan_write_out.rid = obi_out_rsp_i.r.rid;
    assign r_chan_write_out.err = obi_out_rsp_i.r.err;

    assign r_chan_read_out.rid = obi_out_rsp_i.r.rid;
    assign r_chan_read_out.err = obi_out_rsp_i.r.err;
    assign r_chan_read_out.rdata = obi_out_rsp_i.r.rdata;

    assign a_chan_write_out.addr = obi_in_req_i.a.addr;
    assign a_chan_write_out.aid = obi_in_req_i.a.aid;
    assign a_chan_write_out.wdata = obi_in_req_i.a.wdata;

    assign a_chan_read_out.addr = obi_in_req_i.a.addr;
    assign a_chan_read_out.aid = obi_in_req_i.a.aid;


    a_optional_t a_chan_read_optional_in;
    a_optional_t a_chan_write_optional_in;
    r_optional_t r_chan_read_optional_in;
    r_optional_t r_chan_write_optional_in;
    logic[slink_obi_cfg.DataWidth/8-1:0] a_chan_read_be_in;
    logic[slink_obi_cfg.DataWidth/8-1:0] a_chan_write_be_in;


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
    slink_pkg::tx_e tx_type;

    always_comb begin : tx_fifo_in_arbiter

        tx_type = slink_pkg::TxNone;
        payload_out = '0;
        rr_tx_out_arb_d = rr_tx_out_arb_q;

        if (obi_out_rsp_i.rvalid && !issued_reqs_fifo_empty) begin
            // rsp out always prioritized
            payload_out.hdr    = issued_reqs_fifo_data_out.is_write ? slink_pkg::TagRWrite : slink_pkg::TagRRead;
            payload_out.src_id = node_id_i;
            payload_out.dst_id = issued_reqs_fifo_data_out.src_id;

            if (issued_reqs_fifo_data_out.is_write) begin
                payload_out.obi_ch = r_chan_write_out;

            end else begin
                payload_out.obi_ch = r_chan_read_out;
            end

            tx_type = slink_pkg::TxOutgoingR;

        end else if (can_enqueue_tx) begin
            // Round Robin arbiter between req out and transit
            //TODO change the credits out i and payloadsplits to a proper condition. The 3 should represent the tx fifo size.
            //However, we don't know if the tx fifo might be bigger than the rx fifo i.e. tx fifo size times payload splits.
            unique case ({obi_in_req_i.req && (credits_out_i > 3*PayloadSplits), rx_type == slink_pkg::RxTransit})
                2'b01: begin
                    // No request and transit
                    payload_out  = payload_in;
                    tx_type = slink_pkg::TxTransit;
                    rr_tx_out_arb_d = 1'b0;
                end
                2'b10: begin
                    // Request and no transit
                    payload_out.hdr    = obi_in_req_i.a.we ? slink_pkg::TagAWrite : slink_pkg::TagARead;
                    payload_out.src_id = node_id_i;
                    payload_out.dst_id = obi_in_req_i.a.addr[slink_obi_cfg.AddrWidth-1 -: 4];

                    if (obi_in_req_i.a.we) begin
                        payload_out.obi_ch = a_chan_write_out;

                    end else begin
                        payload_out.obi_ch = a_chan_read_out;

                    end

                    tx_type = slink_pkg::TxOutgoingA;
                    rr_tx_out_arb_d = 1'b1;
                end
                2'b11: begin
                    // Request and transit
                    if (rr_tx_out_arb_q) begin
                        payload_out  = payload_in;
                        tx_type = slink_pkg::TxTransit;
                    end else begin
                        payload_out.hdr    = obi_in_req_i.a.we ? slink_pkg::TagAWrite : slink_pkg::TagARead;
                        payload_out.src_id = node_id_i;
                        payload_out.dst_id = obi_in_req_i.a.addr[slink_obi_cfg.AddrWidth-1 -: 4];

                        if (obi_in_req_i.a.we) begin
                            payload_out.obi_ch = a_chan_write_out;

                        end else begin
                            payload_out.obi_ch = a_chan_read_out;

                        end

                        tx_type = slink_pkg::TxOutgoingA;
                    end
                    rr_tx_out_arb_d = ~rr_tx_out_arb_q;
                end
                default: begin
                    // No request and no transit
                    tx_type = slink_pkg::TxNone;
                    payload_out = '0;
                    rr_tx_out_arb_d = rr_tx_out_arb_q;
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
                    slink_pkg::TagARead:  rx_type = slink_pkg::RxIncomingA;
                    slink_pkg::TagAWrite: rx_type = slink_pkg::RxIncomingA;
                    slink_pkg::TagRRead:  rx_type = slink_pkg::RxIncomingR;
                    slink_pkg::TagRWrite: rx_type = slink_pkg::RxIncomingR;
                    default:         rx_type = slink_pkg::RxError;
                endcase 
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

        if (rx_type == slink_pkg::RxIncomingR) begin
            obi_in_rsp_o.rvalid = 1'b1;
            axis_in_rsp_o.tready = 1'b1;
            if (payload_in.hdr == slink_pkg::TagRRead) begin
                obi_in_rsp_o.r.rdata = r_chan_read_in.rdata;
                obi_in_rsp_o.r.rid = r_chan_read_in.rid;
                obi_in_rsp_o.r.err = r_chan_read_in.err;
                obi_in_rsp_o.r.r_optional = r_chan_read_optional_in;

            end else if (payload_in.hdr == slink_pkg::TagRWrite) begin
                obi_in_rsp_o.r.rdata = '0;
                obi_in_rsp_o.r.rid = r_chan_write_in.rid;
                obi_in_rsp_o.r.err = r_chan_write_in.err;
                obi_in_rsp_o.r.r_optional = r_chan_write_optional_in;

            end
        end

        if (rx_type == slink_pkg::RxLoop) begin
            obi_in_rsp_o.rvalid = 1'b1;
            obi_in_rsp_o.r.err = 1'b1;
            axis_in_rsp_o.tready = 1'b1; // Consume and error
        end

        if (rx_type == slink_pkg::RxError) begin
            axis_in_rsp_o.tready = 1'b1; // Consume and discard (not a payload)
        end

        if (rx_type == slink_pkg::RxIncomingA && can_enqueue_response) begin
            obi_out_req_o.req = 1'b1;

            if (payload_in.hdr == slink_pkg::TagARead) begin
                obi_out_req_o.a.addr = a_chan_read_in.addr;
                obi_out_req_o.a.aid = a_chan_read_in.aid;
                obi_out_req_o.a.wdata = '0;
                obi_out_req_o.a.we = 1'b0;
                obi_out_req_o.a.a_optional = a_chan_read_optional_in;
                obi_out_req_o.a.be = a_chan_read_be_in;

            end else if (payload_in.hdr == slink_pkg::TagAWrite) begin
                obi_out_req_o.a.addr = a_chan_write_in.addr;
                obi_out_req_o.a.aid = a_chan_write_in.aid;
                obi_out_req_o.a.wdata = a_chan_write_in.wdata;
                obi_out_req_o.a.we = 1'b1;
                obi_out_req_o.a.a_optional = a_chan_write_optional_in;
                obi_out_req_o.a.be = a_chan_write_be_in;
                
            end

            if (obi_out_rsp_i.gnt) begin
                issued_reqs_fifo_push    = 1'b1;
                axis_in_rsp_o.tready     = 1'b1;
            end
        end

        if (tx_fifo_ready_in) begin
            if (tx_type == slink_pkg::TxOutgoingR) begin
                tx_fifo_valid_in = 1'b1;
                issued_reqs_fifo_pop = 1'b1;

            end else if (tx_type == slink_pkg::TxOutgoingA) begin
                tx_fifo_valid_in = 1'b1;
                obi_in_rsp_o.gnt = 1'b1;

            end else if (tx_type == slink_pkg::TxTransit) begin
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
