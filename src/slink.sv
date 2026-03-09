// Copyright 2022 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
//  - Tim Fischer <fischeti@iis.ee.ethz.ch>
//  - Manuel Eggimann <meggimann@iis.ee.ethz.ch>

`include "common_cells/registers.svh"
`include "common_cells/assertions.svh"
`include "axi_stream/typedef.svh"
`include "rdl_assign.svh"

/// A simple serial link to go off-chip
module slink
  import slink_reg_pkg::*;
#(
  // Number of credits for flow control
  parameter int NumCredits        = 8,
  parameter int ObiAddrWidth      = 32,
  parameter type obi_req_t  = logic,
  parameter type obi_rsp_t  = logic,
  parameter type a_chan_t   = logic,
  parameter type r_chan_t   = logic
) (
  // There are 3 different clock/resets:
  // 1) clk_i & rst_ni: "always-on" clock & reset coming from the SoC domain. Only config registers are conected to this clock
  // 2) clk_sl_i & rst_sl_ni: Same as 1) but clock is gated and reset is SW synchronized. This is the clock that drives the serial link
  //    i.e. protocol, data-link and physical layer all run on this clock and can be clock gated if needed. If no clock gating, reset synchronization
  //    is desired, you can tie clk_sl_i -> clk_i resp. rst_sl_ni -> rst_ni
  // 3) clk_reg_i & rst_reg_ni: peripheral clock and reset. Only connected to RegBus CDC. If NoRegCdc is set, this clock must be the same as 1)
  input  logic                      clk_i,
  input  logic                      rst_ni,
  input  logic                      clk_sl_i,
  input  logic                      rst_sl_ni,
  input  logic                      clk_reg_i,
  input  logic                      rst_reg_ni,
  input  logic                      testmode_i,
  input  obi_req_t                  obi_in_req_i,
  output obi_rsp_t                  obi_in_rsp_o,
  output obi_req_t                  obi_out_req_o,
  input  obi_rsp_t                  obi_out_rsp_i,
  input  obi_req_t                  obi_reg_req_i,
  output obi_rsp_t                  obi_reg_rsp_o,
  input  logic [NumChannels-1:0]    ddr_rcv_clk_i,
  output logic [NumChannels-1:0]    ddr_rcv_clk_o,
  input  logic [NumChannels-1:0][NumLanes-1:0] ddr_i,
  output logic [NumChannels-1:0][NumLanes-1:0] ddr_o
);


  localparam int unsigned NumBitsPerCycle = NumLanes * (1 + EnDdr);
  localparam int unsigned RawModeFifoDepth = 2**Log2RawModeTXFifoDepth;
  localparam int unsigned MaxClkDiv = 2**Log2MaxClkDiv;

  typedef logic [$clog2(NumCredits):0] credit_t;
  typedef logic [NumBitsPerCycle-1:0] phy_data_t;

  // Determine the largest sized AXI channel
  localparam int ObiChannels[2] = {$bits(a_chan_t),
                                    $bits(r_chan_t)};
  localparam int MaxObiChannelBits = slink_pkg::find_max_channel(ObiChannels);


  // The payload that is converted into an AXI stream consists of
  // 1) AXI Beat
  // 2) B Channel (which is always transmitted)
  // 3) Header
  // 4) Credit for flow control
  typedef struct packed {
    logic [MaxObiChannelBits-1:0] obi_ch;
    slink_pkg::tag_e hdr;
    credit_t credit;
  } payload_t;

  localparam int BandWidth = NumChannels * NumBitsPerCycle; // doubled BW if DDR enabled
  localparam int PayloadSplits = ($bits(payload_t) + BandWidth - 1) / BandWidth;
  localparam int RecvFifoDepth = NumCredits * PayloadSplits;

  // Axi stream dimension must be a multiple of 8 bits
  localparam int StreamDataBytes = ($bits(payload_t) + 7) / 8;

  // Typdefs for Axi Stream interface
  // All except tdata_t are unused at the moment
  typedef logic [StreamDataBytes*8-1:0] tdata_t;
  typedef logic [StreamDataBytes-1:0] tstrb_t;
  typedef logic [StreamDataBytes-1:0] tkeep_t;
  typedef logic tid_t;
  typedef logic tdest_t;
  typedef logic tuser_t;

  `AXI_STREAM_TYPEDEF_ALL(axis, tdata_t, tstrb_t, tkeep_t, tid_t, tdest_t, tuser_t)

  logic       obi_reg_rready;

  axis_req_t  axis_out_req, axis_in_req;
  axis_rsp_t  axis_out_rsp, axis_in_rsp;

  slink_reg__out_t reg2hw;
  slink_reg__in_t hw2reg;

  phy_data_t [NumChannels-1:0]  data_link2alloc_data_out;
  logic [NumChannels-1:0]       data_link2alloc_data_out_valid;
  logic                         alloc2data_link_data_out_ready;

  phy_data_t [NumChannels-1:0]  alloc2data_link_data_in;
  logic [NumChannels-1:0]       alloc2data_link_data_in_valid;
  logic [NumChannels-1:0]       data_link2alloc_data_in_ready;

  phy_data_t [NumChannels-1:0]  alloc2phy_data_out;
  logic [NumChannels-1:0]       alloc2phy_data_out_valid;
  logic [NumChannels-1:0]       phy2alloc_data_out_ready;

  phy_data_t [NumChannels-1:0]  phy2alloc_data_in;
  logic [NumChannels-1:0]       phy2alloc_data_in_valid;
  logic [NumChannels-1:0]       alloc2phy_data_in_ready;


  ////////////////////////
  //   PROTOCOL LAYER   //
  ////////////////////////

  slink_prot_layer #(
    .NumCredits     ( NumCredits    ),
    .obi_req_t      ( obi_req_t     ),
    .obi_rsp_t      ( obi_rsp_t     ),
    .axis_req_t     ( axis_req_t    ),
    .axis_rsp_t     ( axis_rsp_t    ),
    .a_chan_t       ( a_chan_t      ),
    .r_chan_t       ( r_chan_t      ),
    .payload_t      ( payload_t     ),
    .credit_t       ( credit_t      )
  ) i_serial_link_protocol (
    .clk_i          ( clk_sl_i        ),
    .rst_ni         ( rst_sl_ni       ),
    .obi_in_req_i   ( obi_in_req_i    ),
    .obi_in_rsp_o   ( obi_in_rsp_o    ),
    .obi_out_req_o  ( obi_out_req_o   ),
    .obi_out_rsp_i  ( obi_out_rsp_i   ),
    .axis_in_req_i  ( axis_in_req     ),
    .axis_in_rsp_o  ( axis_in_rsp     ),
    .axis_out_req_o ( axis_out_req    ),
    .axis_out_rsp_i ( axis_out_rsp    )
  );

  /////////////////////////
  //   DATA LINK LAYER   //
  /////////////////////////

  logic cfg_flow_control_fifo_clear;
  logic cfg_raw_mode_out_data_fifo_clear;
  logic raw_mode_out_data_valid;
  logic [NumChannels-1:0] raw_mode_in_data_valid;
  logic [NumChannels-1:0] raw_mode_out_ch_mask;

  assign cfg_flow_control_fifo_clear =
      reg2hw.flow_control_fifo_clear.wr_data.flow_control_fifo_clear
    & reg2hw.flow_control_fifo_clear.req
    & reg2hw.flow_control_fifo_clear.req_is_wr
    & reg2hw.flow_control_fifo_clear.wr_biten.flow_control_fifo_clear;
  assign cfg_raw_mode_out_data_fifo_clear =
      reg2hw.raw_mode_out_data_fifo_ctrl.wr_data.clear
    & reg2hw.raw_mode_out_data_fifo_ctrl.req
    & reg2hw.raw_mode_out_data_fifo_ctrl.req_is_wr
    & reg2hw.raw_mode_out_data_fifo_ctrl.wr_biten.clear;
  for (genvar i = 0; i < NumChannels; i++) begin : gen_raw_mode_in_data_valid
    assign raw_mode_out_ch_mask[i] =
      reg2hw.raw_mode_out_ch_mask[i].raw_mode_out_ch_mask.value;
  end

  phy_data_t raw_mode_in_data_out;
  logic [$clog2(RawModeFifoDepth)-1:0] raw_mode_out_data_fill_state;
  logic raw_mode_out_data_is_full;

  slink_link_layer #(
    .axis_req_t       ( axis_req_t        ),
    .axis_rsp_t       ( axis_rsp_t        ),
    .phy_data_t       ( phy_data_t        ),
    .NumChannels      ( NumChannels       ),
    .NumLanes         ( NumLanes          ),
    .RecvFifoDepth    ( RecvFifoDepth     ),
    .RawModeFifoDepth ( RawModeFifoDepth  ),
    .PayloadSplits    ( PayloadSplits     ),
    .EnDdr            ( EnDdr             )
  ) i_serial_link_data_link (
    .clk_i                                   ( clk_sl_i                                         ),
    .rst_ni                                  ( rst_sl_ni                                        ),
    .axis_in_req_i                           ( axis_out_req                                     ),
    .axis_in_rsp_o                           ( axis_out_rsp                                     ),
    .axis_out_req_o                          ( axis_in_req                                      ),
    .axis_out_rsp_i                          ( axis_in_rsp                                      ),
    .data_out_o                              ( data_link2alloc_data_out                         ),
    .data_out_valid_o                        ( data_link2alloc_data_out_valid                   ),
    .data_out_ready_i                        ( alloc2data_link_data_out_ready                   ),
    .data_in_i                               ( alloc2data_link_data_in                          ),
    .data_in_valid_i                         ( alloc2data_link_data_in_valid                    ),
    .data_in_ready_o                         ( data_link2alloc_data_in_ready                    ),
    .cfg_flow_control_fifo_clear_i           ( cfg_flow_control_fifo_clear                      ),
    .cfg_raw_mode_en_i                       ( reg2hw.raw_mode_en.raw_mode_en.value ),
    .cfg_raw_mode_in_ch_sel_i                (
      reg2hw.raw_mode_in_ch_sel.raw_mode_in_ch_sel.value[cf_math_pkg::idx_width(NumChannels)-1:0] ),
    .cfg_raw_mode_in_data_o                  ( raw_mode_in_data_out ),
    .cfg_raw_mode_in_data_valid_o            ( raw_mode_in_data_valid                           ),
    .cfg_raw_mode_in_data_ready_i            (
      reg2hw.raw_mode_in_data.req & ~reg2hw.raw_mode_in_data.req_is_wr ),
    .cfg_raw_mode_out_ch_mask_i              ( raw_mode_out_ch_mask                             ),
    .cfg_raw_mode_out_data_i                 (
      phy_data_t'(reg2hw.raw_mode_out_data_fifo.raw_mode_out_data_fifo.value) ),
    .cfg_raw_mode_out_data_valid_i           ( raw_mode_out_data_valid ),
    .cfg_raw_mode_out_en_i                   (
      reg2hw.raw_mode_out_en.raw_mode_out_en.value ),
    .cfg_raw_mode_out_data_fifo_clear_i      ( cfg_raw_mode_out_data_fifo_clear                 ),
    .cfg_raw_mode_out_data_fifo_fill_state_o ( raw_mode_out_data_fill_state ),
    .cfg_raw_mode_out_data_fifo_is_full_o    ( raw_mode_out_data_is_full )
  );

  always_comb begin
    hw2reg.raw_mode_in_data.rd_data = '0;
    hw2reg.raw_mode_in_data.rd_data.raw_mode_in_data = raw_mode_in_data_out;
    hw2reg.raw_mode_out_data_fifo_ctrl.rd_data = '0;
    hw2reg.raw_mode_out_data_fifo_ctrl.rd_data.fill_state = raw_mode_out_data_fill_state;
    hw2reg.raw_mode_out_data_fifo_ctrl.rd_data.is_full = raw_mode_out_data_is_full;
    for (int i = 0; i < NumChannels; i++) begin
      hw2reg.raw_mode_in_data_valid[i].rd_data = '0;
      hw2reg.raw_mode_in_data_valid[i].rd_data.raw_mode_in_data_valid = raw_mode_in_data_valid[i];
      `SLINK_SET_RDL_RD_ACK(raw_mode_in_data_valid[i])
    end
  end

  `SLINK_ASSIGN_RDL_RD_ACK(raw_mode_in_data)
  `SLINK_ASSIGN_RDL_RD_ACK(raw_mode_out_data_fifo_ctrl)
  `SLINK_ASSIGN_RDL_WR_ACK(raw_mode_out_data_fifo_ctrl)
  `SLINK_ASSIGN_RDL_WR_ACK(flow_control_fifo_clear)

  `FF(raw_mode_out_data_valid, reg2hw.raw_mode_out_data_fifo.raw_mode_out_data_fifo.swmod, '0)

  ///////////////////////
  // CHANNEL ALLOCATOR //
  ///////////////////////

  if (!EnChAlloc) begin : gen_no_channel_alloc
    // Don't instantiate the channel allocator for the single channel serial
    // link variant. We just feedthrough all the connections

    assign alloc2phy_data_out = data_link2alloc_data_out;
    assign alloc2phy_data_out_valid = data_link2alloc_data_out_valid;
    assign alloc2data_link_data_out_ready = phy2alloc_data_out_ready;

    assign alloc2data_link_data_in = phy2alloc_data_in;
    assign alloc2data_link_data_in_valid = phy2alloc_data_in_valid;
    assign alloc2phy_data_in_ready = data_link2alloc_data_in_ready;

  end else begin : gen_channel_alloc

    logic cfg_tx_clear, cfg_rx_clear;
    logic cfg_tx_flush_trigger;
    logic [NumChannels-1:0] cfg_tx_channel_en, cfg_rx_channel_en;

    assign cfg_tx_clear = reg2hw.channel_alloc_tx_ctrl.wr_data.clear
      & reg2hw.channel_alloc_tx_ctrl.req
      & reg2hw.channel_alloc_tx_ctrl.req_is_wr
      & reg2hw.channel_alloc_tx_ctrl.wr_biten.clear;
    assign cfg_rx_clear = reg2hw.channel_alloc_rx_ctrl.wr_data.clear
      & reg2hw.channel_alloc_rx_ctrl.req
      & reg2hw.channel_alloc_rx_ctrl.req_is_wr
      & reg2hw.channel_alloc_rx_ctrl.wr_biten.clear;
    assign cfg_tx_flush_trigger = reg2hw.channel_alloc_tx_ctrl.wr_data.flush
      & reg2hw.channel_alloc_tx_ctrl.req
      & reg2hw.channel_alloc_tx_ctrl.req_is_wr
      & reg2hw.channel_alloc_tx_ctrl.wr_biten.flush;
    for (genvar i = 0; i < NumChannels; i++) begin : gen_channel_en
      assign cfg_tx_channel_en[i] =
        reg2hw.channel_alloc_tx_ch_en[i].channel_alloc_tx_ch_en.value;
      assign cfg_rx_channel_en[i] =
        reg2hw.channel_alloc_rx_ch_en[i].channel_alloc_rx_ch_en.value;
    end

    slink_ch_alloc #(
      .phy_data_t  ( phy_data_t    ),
      .NumChannels ( NumChannels   )
    ) i_channel_allocator(
      .clk_i                     ( clk_sl_i                                       ),
      .rst_ni                    ( rst_sl_ni                                      ),
      .cfg_tx_clear_i            ( cfg_tx_clear                                   ),
      .cfg_tx_channel_en_i       ( cfg_tx_channel_en                              ),
      .cfg_tx_bypass_en_i        ( reg2hw.channel_alloc_tx_cfg.bypass_en.value ),
      .cfg_tx_auto_flush_en_i    ( reg2hw.channel_alloc_tx_cfg.auto_flush_en.value ),
      .cfg_tx_auto_flush_count_i ( reg2hw.channel_alloc_tx_cfg.auto_flush_count.value ),
      .cfg_tx_flush_trigger_i    ( cfg_tx_flush_trigger                           ),
      .cfg_rx_clear_i            ( cfg_rx_clear                                   ),
      .cfg_rx_bypass_en_i        ( reg2hw.channel_alloc_rx_cfg.bypass_en.value ),
      .cfg_rx_channel_en_i       ( cfg_rx_channel_en                              ),
      .cfg_rx_auto_flush_en_i    ( reg2hw.channel_alloc_rx_cfg.auto_flush_en.value ),
      .cfg_rx_auto_flush_count_i ( reg2hw.channel_alloc_rx_cfg.auto_flush_count.value ),
      .cfg_rx_sync_en_i          ( reg2hw.channel_alloc_rx_cfg.sync_en.value ),
      // From Data Link Layer
      .data_out_i                ( data_link2alloc_data_out                       ),
      .data_out_valid_i          ( data_link2alloc_data_out_valid                 ),
      .data_out_ready_o          ( alloc2data_link_data_out_ready                 ),
      // To Phy
      .data_out_o                ( alloc2phy_data_out                             ),
      .data_out_valid_o          ( alloc2phy_data_out_valid                       ),
      .data_out_ready_i          ( phy2alloc_data_out_ready                       ),
      // From Phy
      .data_in_i                 ( phy2alloc_data_in                              ),
      .data_in_valid_i           ( phy2alloc_data_in_valid                        ),
      .data_in_ready_o           ( alloc2phy_data_in_ready                        ),
      // To Data Link Layer
      .data_in_o                 ( alloc2data_link_data_in                        ),
      .data_in_valid_o           ( alloc2data_link_data_in_valid                  ),
      .data_in_ready_i           ( data_link2alloc_data_in_ready                  )
    );
  end


  ////////////////////////
  //   PHYSICAL LAYER   //
  ////////////////////////

  for (genvar i = 0; i < NumChannels; i++) begin : gen_phy_channels
    serial_link_physical #(
      .NumLanes         ( NumLanes          ),
      .FifoDepth        ( RawModeFifoDepth  ),
      .MaxClkDiv        ( MaxClkDiv         ),
      .EnDdr            ( EnDdr             ),
      .phy_data_t       ( phy_data_t        )
    ) i_serial_link_physical (
      .clk_i             ( clk_sl_i                     ),
      .rst_ni            ( rst_sl_ni                    ),
      .clk_div_i         ( reg2hw.tx_phy_clk_div[i].clk_divs.value ),
      .clk_shift_start_i ( reg2hw.tx_phy_clk_start[i].clk_divs.value ),
      .clk_shift_end_i   ( reg2hw.tx_phy_clk_end[i].clk_shift_end.value ),
      .ddr_rcv_clk_i     ( ddr_rcv_clk_i[i]             ),
      .ddr_rcv_clk_o     ( ddr_rcv_clk_o[i]             ),
      .data_out_i        ( alloc2phy_data_out[i]        ),
      .data_out_valid_i  ( alloc2phy_data_out_valid[i]  ),
      .data_out_ready_o  ( phy2alloc_data_out_ready[i]  ),
      .data_in_o         ( phy2alloc_data_in[i]         ),
      .data_in_valid_o   ( phy2alloc_data_in_valid[i]   ),
      .data_in_ready_i   ( alloc2phy_data_in_ready[i]   ),
      .ddr_i             ( ddr_i[i]                     ),
      .ddr_o             ( ddr_o[i]                     )
    );
  end

  /////////////////////////////////
  //   CONFIGURATION REGISTERS   //
  /////////////////////////////////

  slink_reg i_serial_link_reg (
    .clk  (clk_i),
    .arst_n (rst_ni),

    .s_obi_req    ( obi_reg_req_i.req      ),
    .s_obi_gnt    ( obi_reg_rsp_o.gnt      ),
    .s_obi_addr   ( obi_reg_req_i.a.addr   ),
    .s_obi_we     ( obi_reg_req_i.a.we     ),
    .s_obi_be     ( obi_reg_req_i.a.be     ),
    .s_obi_wdata  ( obi_reg_req_i.a.wdata  ),
    .s_obi_aid    ( obi_reg_req_i.a.aid    ),
    .s_obi_rvalid ( obi_reg_rsp_o.rvalid   ),
    .s_obi_rready ( obi_reg_rready         ),
    .s_obi_rdata  ( obi_reg_rsp_o.r.rdata  ),
    .s_obi_err    ( obi_reg_rsp_o.r.err    ),
    .s_obi_rid    ( obi_reg_rsp_o.r.rid    ),
    .hwif_in      ( hw2reg            ),
    .hwif_out     ( reg2hw            )
  );

  //TODO remove the rready in hte cfg regs and then remove this and get rid of this annoying optional mess
  always_comb begin
    obi_reg_rsp_o.r.r_optional = '0;
    obi_reg_rready = '1;
  end


  if (EnChAlloc) begin : gen_channel_alloc_regs
    `SLINK_ASSIGN_RDL_WR_ACK(channel_alloc_tx_ctrl)
    `SLINK_ASSIGN_RDL_WR_ACK(channel_alloc_rx_ctrl)
  end else begin : gen_no_channel_alloc_regs
    assign hw2reg.channel_alloc_tx_ctrl = '{default: '0};
    assign hw2reg.channel_alloc_rx_ctrl = '{default: '0};
  end

  ////////////////////
  //   ASSERTIONS   //
  ////////////////////

  `ASSERT_INIT(RawModeFifoDim, RecvFifoDepth >= RawModeFifoDepth)

endmodule : slink
