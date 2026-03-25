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
    parameter type axis_req_t = logic,
    parameter type axis_rsp_t = logic,
    parameter type a_chan_t   = logic,
    parameter type r_chan_t   = logic,
    parameter type payload_t  = logic
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
    output axis_rsp_t axis_in_rsp_o
);

    localparam int ADDR_WIDTH = $bits(obi_in_req_i.a.addr);
    localparam int TX_FIFO_DEPTH = 3;


    logic entropy_q, entropy_d;
    payload_t payload_out, payload_in;


    logic tx_fifo_valid_out, tx_fifo_ready_out;
    logic tx_fifo_valid_in, tx_fifo_ready_in;
    payload_t tx_fifo_data_in, tx_fifo_data_out;
    logic[2:0] tx_fifo_fill_state; // TODO ptr, not counter


    logic[3:0] issued_reqs_src_ids_fifo_data_in;
    logic[3:0] issued_reqs_src_ids_fifo_data_out;
    logic[1:0] issued_reqs_src_ids_fifo_fill_state; // TODO ptr, not counter
    logic issued_reqs_src_ids_fifo_pop;
    logic issued_reqs_src_ids_fifo_push;
    logic issued_reqs_src_ids_fifo_full;
    logic issued_reqs_src_ids_fifo_empty;


    fifo_v3 #(
        .DEPTH  ( 2           ),
        .dtype  ( logic[3:0]  )
    ) i_issued_reqs_src_ids_fifo (
        .clk_i      ( clk_i               ),
        .rst_ni     ( rst_ni              ),
        .flush_i    ( 1'b0                ),
        .testmode_i ( 1'b0                ),
        .full_o     ( issued_reqs_src_ids_fifo_full ),
        .empty_o    ( issued_reqs_src_ids_fifo_empty ),
        .usage_o    ( issued_reqs_src_ids_fifo_fill_state ),
        .data_i     ( issued_reqs_src_ids_fifo_data_in ),
        .push_i     ( issued_reqs_src_ids_fifo_push ),
        .data_o     ( issued_reqs_src_ids_fifo_data_out ),
        .pop_i      ( issued_reqs_src_ids_fifo_pop )
    );



    logic can_enqueue_response, can_enqueue_tx;

    assign can_enqueue_response = !issued_reqs_src_ids_fifo_full && tx_fifo_ready_in; //(tx_fifo_fill_state < TX_FIFO_DEPTH);

    assign can_enqueue_tx = ((TX_FIFO_DEPTH - tx_fifo_fill_state) > issued_reqs_src_ids_fifo_fill_state);


    slink_pkg::rx_e rx_type;
    slink_pkg::tx_e tx_type;

    always_comb begin : tx_fifo_in_arbiter

        tx_type = slink_pkg::TxNone;
        payload_out = '0;

        if (obi_out_rsp_i.rvalid && !issued_reqs_src_ids_fifo_empty) begin
            payload_out.hdr    = slink_pkg::TagR;
            payload_out.src_id = node_id_i;
            payload_out.dst_id = issued_reqs_src_ids_fifo_data_out;
            payload_out.obi_ch = obi_out_rsp_i.r;
            tx_type = slink_pkg::TxOutgoingR;

        end else if (obi_in_req_i.req && can_enqueue_tx && (rx_type != slink_pkg::RxTransit || ~entropy_q)) begin
            payload_out.hdr    = slink_pkg::TagA;
            payload_out.src_id = node_id_i;
            payload_out.dst_id = obi_in_req_i.a.addr[ADDR_WIDTH-1 -: 4];
            payload_out.obi_ch = obi_in_req_i.a;
            tx_type = slink_pkg::TxOutgoingA;

        end else if (rx_type == slink_pkg::RxTransit && can_enqueue_tx && (~obi_in_req_i.req || entropy_q)) begin
            payload_out  = payload_in;
            tx_type = slink_pkg::TxTransit;
            
        end
    end


    always_comb begin : rx_redirector

        rx_type = slink_pkg::RxNone;

        if (axis_in_req_i.tvalid) begin
            if (payload_in.dst_id == node_id_i) begin
                unique case (payload_in.hdr)
                    slink_pkg::TagA: rx_type = slink_pkg::RxIncomingA;
                    slink_pkg::TagR: rx_type = slink_pkg::RxIncomingR;
                    default:         rx_type = slink_pkg::RxError;
                endcase
            end else if (payload_in.src_id == node_id_i) begin
                rx_type = slink_pkg::RxLoop;
            end else if (payload_in.hdr == slink_pkg::TagA || payload_in.hdr == slink_pkg::TagR) begin
                rx_type = slink_pkg::RxTransit;
            end else begin
                rx_type = slink_pkg::RxError;
            end
        end
    end


    always_comb begin : commiter

        obi_out_req_o.a = a_chan_t'(payload_in.obi_ch);
        obi_in_rsp_o.r  = r_chan_t'(payload_in.obi_ch);
        issued_reqs_src_ids_fifo_data_in = payload_in.src_id;

        tx_fifo_valid_in = 1'b0;
        issued_reqs_src_ids_fifo_pop = 1'b0;
        issued_reqs_src_ids_fifo_push = 1'b0;
        obi_in_rsp_o.gnt = 1'b0;
        obi_in_rsp_o.rvalid = 1'b0;
        axis_in_rsp_o.tready = 1'b0;
        obi_out_req_o.req = 1'b0;

        if (rx_type == slink_pkg::RxIncomingR) begin
            obi_in_rsp_o.rvalid = 1'b1;
            axis_in_rsp_o.tready = 1'b1;
        end

        if (rx_type == slink_pkg::RxLoop) begin
            axis_in_rsp_o.tready = 1'b1; // Consume and discard (TODO: Needs to error out in future)
        end

        if (rx_type == slink_pkg::RxError) begin
            axis_in_rsp_o.tready = 1'b1; // Consume and discard (TODO: Needs to error out in future)
        end

        if (rx_type == slink_pkg::RxIncomingA && can_enqueue_response && can_enqueue_tx) begin
            obi_out_req_o.req = 1'b1;

            if (obi_out_rsp_i.gnt) begin
                issued_reqs_src_ids_fifo_push    = 1'b1;
                axis_in_rsp_o.tready             = 1'b1;
            end
        end

        if (tx_fifo_ready_in) begin
            if (tx_type == slink_pkg::TxOutgoingR) begin
                tx_fifo_valid_in = 1'b1;
                issued_reqs_src_ids_fifo_pop = 1'b1;

            end else if (tx_type == slink_pkg::TxOutgoingA && !obi_out_req_o.req) begin
                tx_fifo_valid_in = 1'b1;
                obi_in_rsp_o.gnt = 1'b1;

            end else if (tx_type == slink_pkg::TxTransit && !obi_out_req_o.req) begin
                tx_fifo_valid_in = 1'b1;
                axis_in_rsp_o.tready = 1'b1;

            end
        end
    end


    assign tx_fifo_data_in = payload_out;
    assign axis_out_req_o.tvalid = tx_fifo_valid_out;
    assign axis_out_req_o.t.data = tx_fifo_data_out;
    assign tx_fifo_ready_out = axis_out_rsp_i.tready;

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


    assign entropy_d = entropy_q + (axis_out_req_o.tvalid & axis_out_rsp_i.tready);
    `FF(entropy_q, entropy_d, '0);



    ////////////////////
    //   ASSERTIONS   //
    ////////////////////
    
    `ASSERT(AxisStable, axis_out_req_o.tvalid & !axis_out_rsp_i.tready |=> $stable(axis_out_req_o.t))
    `ASSERT(AxisHandshake, axis_out_req_o.tvalid & !axis_out_rsp_i.tready |=> axis_out_req_o.tvalid)
endmodule
