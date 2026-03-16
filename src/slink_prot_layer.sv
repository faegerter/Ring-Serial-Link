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
    input  obi_req_t  obi_in_req_i,
    output obi_rsp_t  obi_in_rsp_o,
    output obi_req_t  obi_out_req_o,
    input  obi_rsp_t  obi_out_rsp_i,
    output axis_req_t axis_out_req_o,
    input  axis_rsp_t axis_out_rsp_i,
    input  axis_req_t axis_in_req_i,
    output axis_rsp_t axis_in_rsp_o
    );


    typedef enum logic [1:0] {
        Idle     = 2'b00,
        TxPend    = 2'b01,
        RxPend    = 2'b10,
        RxTxPend   = 2'b11
    } commiter_state_e;

    logic entropy_q, entropy_d;
    commiter_state_e commiter_state_q, commiter_state_d;
    payload_t payload_out, payload_in;


    logic a_gnt, r_gnt, req_to_send;

    logic axis_reg_valid_out, axis_reg_ready_out;
    logic axis_reg_valid_in, axis_reg_ready_in;
    payload_t axis_reg_data_in, axis_reg_data_out;


    always_comb begin : commiter
        a_gnt  = 1'b0;
        r_gnt = 1'b0;
        commiter_state_d = commiter_state_q;
        
        unique case(commiter_state_q)
            Idle: begin
                if (obi_in_req_i.req) begin
                    a_gnt = (obi_out_req_o.req) ? entropy_q : 1'b1;
                end
                if(req_to_send) begin
                    r_gnt = (obi_in_req_i.req) ? ~entropy_q : 1'b1;
                end
                if(obi_in_rsp_o.gnt & a_gnt) begin
                    commiter_state_d = RxPend;
                end
                if(obi_out_rsp_i.gnt & r_gnt) begin
                    commiter_state_d = TxPend;
                end
            end
            RxPend: begin 
                if(req_to_send) begin 
                    r_gnt = 1'b1;
                end
                if(obi_in_rsp_o.rvalid)begin 
                    commiter_state_d = (r_gnt & obi_out_rsp_i.gnt) ? TxPend : Idle;
                end else begin
                    commiter_state_d = (r_gnt & obi_out_rsp_i.gnt) ? RxTxPend : RxPend;
                end
            end
            TxPend: begin 
                if(obi_in_req_i.req) begin 
                    a_gnt = 1'b1;
                end
                if(obi_out_rsp_i.rvalid)begin 
                    commiter_state_d = (a_gnt & obi_in_rsp_o.gnt) ? RxPend : Idle;
                end else begin
                    commiter_state_d = (a_gnt & obi_in_rsp_o.gnt) ? RxTxPend : TxPend;
                end
            end
            RxTxPend: begin
                if(obi_in_rsp_o.rvalid)begin
                    commiter_state_d = TxPend;
                end 
                if(obi_out_rsp_i.rvalid)begin 
                    commiter_state_d = RxPend;
                end
            end
            default:;
        endcase
    end



    `FF(commiter_state_q, commiter_state_d, Idle)


    always_comb begin : sender
        payload_out = '0;

        if (a_gnt) begin
            payload_out.obi_ch = obi_in_req_i.a;
            payload_out.hdr = slink_pkg::TagA;
        end
        else if(r_gnt)begin 
            payload_out.obi_ch = obi_out_rsp_i.r;
            payload_out.hdr = slink_pkg::TagR;
        end

        //Send out an OBI beat (!TagIdle)
        axis_reg_valid_in = (payload_out.hdr != slink_pkg::TagIdle);

        // Send responses if request was sent
        obi_in_rsp_o.gnt = a_gnt & axis_reg_ready_in & axis_reg_valid_in;
        obi_out_req_o.req = r_gnt & axis_reg_ready_in & axis_reg_valid_in;
    end


    assign axis_reg_data_in = payload_out;
    assign axis_out_req_o.tvalid = axis_reg_valid_out;
    assign axis_out_req_o.t.data = axis_reg_data_out;
    assign axis_reg_ready_out = axis_out_rsp_i.tready;

    stream_fifo #(
        .DEPTH  ( 2           ),
        .T      (  payload_t  )
    ) i_axis_out_reg (
        .clk_i      ( clk_i               ),
        .rst_ni     ( rst_ni              ),
        .flush_i    ( 1'b0                ),
        .testmode_i ( 1'b0                ),
        .usage_o    (                     ),
        .valid_i    ( axis_reg_valid_in   ),
        .ready_o    ( axis_reg_ready_in   ),
        .data_i     ( axis_reg_data_in    ),
        .valid_o    ( axis_reg_valid_out  ),
        .ready_i    ( axis_reg_ready_out  ),
        .data_o     ( axis_reg_data_out   )
    );

    logic obi_ch_sent;


    assign obi_ch_sent = (obi_out_req_o.req & obi_out_rsp_i.gnt) | (obi_in_rsp_o.rvalid);

    assign payload_in = payload_t'(axis_in_req_i.t.data);


    always_comb begin : unpacker
        obi_in_rsp_o.rvalid = 1'b0;
        req_to_send = 1'b0;

        axis_in_rsp_o = '0;

        obi_out_req_o.a = a_chan_t'(payload_in.obi_ch);
        obi_in_rsp_o.r = r_chan_t'(payload_in.obi_ch);

        if (axis_in_req_i.tvalid) begin
            req_to_send = (payload_in.hdr == slink_pkg::TagA);
            obi_in_rsp_o.rvalid = (payload_in.hdr == slink_pkg::TagR);
             begin
                // accept payload if either one of them was able to send
                if (obi_ch_sent) begin
                    axis_in_rsp_o.tready = 1'b1;
                end
            end
        end
    end


    assign entropy_d = entropy_q + (axis_out_req_o.tvalid & axis_out_rsp_i.tready);
    `FF(entropy_q, entropy_d, '0);



    ////////////////////
    //   ASSERTIONS   //
    ////////////////////
    
    `ASSERT(AxisStable, axis_out_req_o.tvalid & !axis_out_rsp_i.tready |=> $stable(axis_out_req_o.t))
    `ASSERT(AxisHandshake, axis_out_req_o.tvalid & !axis_out_rsp_i.tready |=> axis_out_req_o.tvalid)
    `ASSERT_INIT(ForceSendTh, ForceSendThresh > 0)

endmodule
