// Copyright 2022 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Author: Tim Fischer <fischeti@iis.ee.ethz.ch>


`include "common_cells/registers.svh"
`include "common_cells/assertions.svh"



//TODO put in the changed slink module
`include "obi/typedef.svh"
//Link to file:
//https://github.com/pulp-platform/obi/blob/main/include/obi/typedef.svh
//TODO add to makefile etc such that it will be automatically downloaded and the structs are instatiated when compiling.

module slink_prot_layer #(
    parameter type obi_req_t  = logic,
    parameter type obi_rsp_t  = logic,
    parameter type axis_req_t = logic,
    parameter type axis_rsp_t = logic,
    parameter type a_chan_t  = logic,
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
  input  axi_rsp_t  obi_out_rsp_i,
  output axis_req_t axis_out_req_o,
  input  axis_rsp_t axis_out_rsp_i,
  input  axis_req_t axis_in_req_i,
  output axis_rsp_t axis_in_rsp_o
);


  typedef enum logic [0:0] {
    Idle     = 1'b0,
    RWPend = 1'b1
  } commiter_state_e;

    commiter_state_e commiter_state_q, commiter_state_d;
    payload_t payload_out, payload_in;

    credit_t credits_out_q, credits_out_d;
    credit_t credits_to_send_q, credits_to_send_d;
    logic credit_to_send_force;


  logic gnt, w_enable;

  logic axis_reg_valid_out, axis_reg_ready_out;
  logic axis_reg_valid_in, axis_reg_ready_in;
  payload_t axis_reg_data_in, axis_reg_data_out;


  always_comb begin : commiter
    gnt  = 1'b0;
    commiter_state_d = commiter_state_q;
    w_enable_d = w_enable_q;
    
    unique case(commiter_state_q)
      Idle: begin
        if (obi_in_req_i.req) begin
          gnt = 1'b1;
          //TODO check if this is clean. Could be an if condition.
          w_enable_d = obi_in_req_i.we;
          commiter_state_d = RWPend;
        end
        else begin 
          //TODO check if this is the best way to do it since I'm supposing that the we from the OBI Manager is only active for one cycle here 
          w_enable_d = 1'b0;
        end
      end
      RWPend: begin
        //TODO add logic to differentiate between cfg registers and axi stream
        //TODO add end conditions to deassert the w_enable
        //if (axi_in_rsp_o.r_valid & axi_in_req_i.r_ready & axi_in_rsp_o.r.last) begin
        //  commiter_state_d[0] = 1'b0; // AwPend or Idle
        //end
        //if (axi_in_req_i.w_valid & axi_in_rsp_o.w_ready & axi_in_req_i.w.last) begin
        //  commiter_state_d[1] = 1'b0; // ArPend or Idle
        end
      end

      default:;
    endcase

end


`FF(commiter_state_q, commiter_state_d, Idle)
`FF(w_enable_q, w_enable_d, Idle)
//TODO check if all or most of the OBI signals require buffering within registers. (Simulating croc in order to see)

//Nothing is really propelry implemented down here.

  always_comb begin : sender
    payload_out = '0;
    payload_out.credit = credits_to_send_q;

    if (gnt & obi_in_req_i.we) begin
      payload_out.axi_ch = axi_in_req_i.aw;
      payload_out.hdr = slink_pkg::TagW;
    end else if (gnt & ~obi_in_req_i.we) begin
      payload_out.axi_ch = axi_out_rsp_i.r;
      payload_out.hdr = slink_pkg::TagR;
    end

    // There are three reasons to send out a packet:
    // 1) Send out an AXI beat (!TagIdle)
    // 2) Return a B response (b_valid)
    // 3) Send an empty packet with credits (credits_to_send_force)
    axis_reg_valid_in = (payload_out.hdr != slink_pkg::TagIdle) | payload_out.b_valid | credit_to_send_force;

    // There is a potential deadlock situation, when the last credit on the local side
    // is consumed and all the credits from the other side are currently in-flight.
    // To prevent this situation, the last credit is only consumed if credit is also sent back
    if (credits_out_q == 0) begin
      axis_reg_valid_in = 1'b0;
    end else if (credits_out_q == 1 && credits_to_send_q == 0) begin
      axis_reg_valid_in = 1'b0;
    end

    // Send responses if request was sent
    axi_in_rsp_o.aw_ready = aw_gnt & axis_reg_ready_in & axis_reg_valid_in;
    axi_in_rsp_o.w_ready  = w_gnt & axis_reg_ready_in & axis_reg_valid_in;
    axi_out_req_o.b_ready = b_gnt & axis_reg_ready_in & axis_reg_valid_in;
    axi_in_rsp_o.ar_ready = ar_gnt & axis_reg_ready_in & axis_reg_valid_in;
    axi_out_req_o.r_ready = r_gnt & axis_reg_ready_in & axis_reg_valid_in;
  end

  // assign axis_reg_valid_in = ((payload_out.hdr != TagIdle) | payload_out.b_valid |
                              // credit_to_send_force) & (credits_out_q != 0);
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