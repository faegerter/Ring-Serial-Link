// Copyright 2022 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Author: Tim Fischer <fischeti@iis.ee.ethz.ch>


`include "common_cells/registers.svh"
`include "common_cells/assertions.svh"



//TODO put in the changed slink module
//`include "obi/typedef.svh"
//Link to file:
//https://github.com/pulp-platform/obi/blob/main/include/obi/typedef.svh
//TODO add to makefile etc such that it will be automatically downloaded and the structs are instatiated when compiling.

module slink_prot_layer #(
    parameter type obi_req_t  = logic,
    parameter type obi_rsp_t  = logic,
    parameter type axis_req_t = logic,
    parameter type axis_rsp_t = logic,
    parameter type a_chan_t   = logic,
    parameter type r_chan_t   = logic,
    parameter type payload_t  = logic,
    parameter type credit_t   = logic,
    // For credit-based control flow
    parameter int NumCredits  = -1,
    // Force send out credits belonging to the other side
    // after ForceSendThresh is reached
    localparam int ForceSendThresh  = NumCredits - 4
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
    RPend    = 2'b01,
    APend    = 2'b10,
    ARPend   = 2'b11
  } commiter_state_e;

    logic entropy_q, entropy_d;
    commiter_state_e commiter_state_q, commiter_state_d;
    payload_t payload_out, payload_in;

    credit_t credits_out_q, credits_out_d;
    credit_t credits_to_send_q, credits_to_send_d;
    logic credit_to_send_force;


  logic gnt_a, gnt_r;

  logic axis_reg_valid_out, axis_reg_ready_out;
  logic axis_reg_valid_in, axis_reg_ready_in;
  payload_t axis_reg_data_in, axis_reg_data_out;


  always_comb begin : commiter
    gnt_a  = 1'b0;
    gnt_r = 1'b0;
    commiter_state_d = commiter_state_q;
    
    unique case(commiter_state_q)
      Idle: begin
        if (obi_in_req_i.req) begin
          gnt_a = (obi_out_req_o.req) ? entropy_q : 1'b1;
        end
        if(obi_out_req_o.req) begin
          gnt_r = (obi_in_req_i.req) ? ~entropy_q : 1'b1;
        end
        if(obi_in_rsp_o.gnt & gnt_a) begin
          commiter_state_d = APend;
        end
        if(obi_out_rsp_i.gnt & gnt_r) begin
          commiter_state_d = RPend;
        end
      end
      APend: begin 
        if(obi_out_req_o.req) begin 
          gnt_r = 1'b1;
        end
        if(obi_in_rsp_o.rvalid)begin 
          commiter_state_d = (gnt_r & obi_out_rsp_i.gnt) ? RPend : Idle;
        end else begin
          commiter_state_d = (gnt_r & obi_out_rsp_i.gnt) ? ARPend : APend;
        end
      end
      RPend: begin 
        if(obi_in_req_i.req) begin 
          gnt_a = 1'b1;
        end
        if(obi_out_rsp_i.rvalid)begin 
          commiter_state_d = (gnt_a & obi_in_rsp_o.gnt) ? APend : Idle;
        end else begin
          commiter_state_d = (gnt_a & obi_in_rsp_o.gnt) ? ARPend : RPend;
        end
      end
      ARPend: begin
          if(obi_in_rsp_o.rvalid)begin
            commiter_state_d = RPend;
          end 
          if(obi_out_rsp_i.rvalid)begin 
            commiter_state_d = APend;
          end
        end
      default:;
    endcase
end



`FF(commiter_state_q, commiter_state_d, Idle)


  always_comb begin : sender
    payload_out = '0;
    payload_out.credit = credits_to_send_q;

    if (gnt_a) begin
      payload_out.obi_ch = obi_in_req_i.a;
      //TODO change slink_pkg to OBI channels
      payload_out.hdr = slink_pkg::TagA;
    end
    else if(gnt_r)begin 
      payload_out.obi_ch = obi_out_rsp_i.r;
      //TODO change slink_pkg to OBI channels
      payload_out.hdr = slink_pkg::TagR;
    end

    // There are two reasons to send out a packet:
    // 1) Send out an OBI beat (!TagIdle)
    // 2) Send an empty packet with credits (credits_to_send_force)
    axis_reg_valid_in = (payload_out.hdr != slink_pkg::TagIdle) | credit_to_send_force;

    // There is a potential deadlock situation, when the last credit on the local side
    // is consumed and all the credits from the other side are currently in-flight.
    // To prevent this situation, the last credit is only consumed if credit is also sent back
    if (credits_out_q == 0) begin
      axis_reg_valid_in = 1'b0;
    end else if (credits_out_q == 1 && credits_to_send_q == 0) begin
      axis_reg_valid_in = 1'b0;
    end

    // Send responses if request was sent
    // TODOadd condition for sending gnt when communicating with cfg regs
    obi_in_rsp_o.gnt = gnt_a & axis_reg_ready_in & axis_reg_valid_in;
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
  logic credit_only_packet;



  assign obi_ch_sent = (obi_out_req_o.req & obi_out_rsp_i.gnt) | (obi_in_rsp_o.rvalid & obi_out_rsp_i.rvalid);

  assign payload_in = payload_t'(axis_in_req_i.t.data);
  assign credit_only_packet = (payload_in.hdr == slink_pkg::TagIdle);

  typedef enum logic { Normal, Sync } unpack_state_e;

  unpack_state_e unpack_state_q, unpack_state_d;

  always_comb begin : unpacker
    obi_out_req_o.req = 1'b0;
    obi_in_rsp_o.rvalid = 1'b0;

    axis_in_rsp_o = '0;

    obi_out_req_o.a = a_chan_t'(payload_in.obi_ch);
    obi_in_rsp_o.r = r_chan_t'(payload_in.obi_ch);

        if (axis_in_req_i.tvalid) begin
          obi_out_req_o.req = (payload_in.hdr == slink_pkg::TagA);
          obi_in_rsp_o.rvalid = (payload_in.hdr == slink_pkg::TagR);
          if (credit_only_packet) begin
            axis_in_rsp_o.tready = 1'b1;
          end else begin
            // accept payload if either one of them was able to send
            if (obi_ch_sent) begin
              axis_in_rsp_o.tready = 1'b1;
            end
          end
        end

  end


assign entropy_d = entropy_q + (axis_out_req_o.tvalid & axis_out_rsp_i.tready);
`FF(entropy_q, entropy_d, '0);

  //////////////////////
  //   FLOW CONTROL   //
  //////////////////////

  // Flow control is theoretically part of the data link layer.
  // However it is much simpler to implement it here where we have
  // simple Handshake interfaces

  always_comb begin
    credits_out_d = credits_out_q;
    credits_to_send_d = credits_to_send_q;
    credit_to_send_force = 1'b0;

    // Send empty packets with credits if there are too many
    // credits to send but no AXI request transaction
    if (credits_to_send_q >= ForceSendThresh) begin
      credit_to_send_force = 1'b1;
    end

    // The order of the two if blocks matter!
    if (axis_reg_valid_in & axis_reg_ready_in) begin
      credits_out_d--;
      credits_to_send_d = 0;
    end

    if (axis_in_req_i.tvalid & axis_in_rsp_o.tready) begin
      credits_out_d += payload_in.credit;
      credits_to_send_d++;
    end
  end

  `FF(credits_out_q, credits_out_d, NumCredits)
  `FF(credits_to_send_q, credits_to_send_d, 0)

  ////////////////////
  //   ASSERTIONS   //
  ////////////////////
  // `ASSERT(AxiComitterAw, axi_in_req_i.w_valid & axi_in_rsp_o.w_ready & axi_in_req_i.w.last
  //         |=> $fell(commiter_state_q[1]))
  // `ASSERT(AxiComitterAr, axi_in_rsp_o.r_valid & axi_in_req_i.r_ready & axi_in_rsp_o.r.last
  //         |=> $fell(commiter_state_q[0]))
  // `ASSERT(AxisStable, axis_out_req_o.tvalid & !axis_out_rsp_i.tready |=> $stable(axis_out_req_o.t))
  // `ASSERT(AxisHandshake, axis_out_req_o.tvalid & !axis_out_rsp_i.tready |=> axis_out_req_o.tvalid)
  // `ASSERT_INIT(ForceSendTh, ForceSendThresh > 0)
  // `ASSERT(MaxCredits, credits_out_q <= NumCredits)
  // `ASSERT(MaxSendCredits, credits_to_send_q <= NumCredits)

endmodule
