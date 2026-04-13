// Copyright 2022 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Author: Tim Fischer <fischeti@iis.ee.ethz.ch>

/// A simple package for common serial link types and functions
package slink_pkg;

  typedef enum logic [1:0]  {
    TagAWrite    = 2'd0,
    TagARead     = 2'd1,
    TagRWrite    = 2'd2,
    TagRRead     = 2'd3
  } tag_e;

  typedef enum logic [2:0]  {
    RxNone      = 3'd0,
    RxTransit   = 3'd1,
    RxIncomingARead = 3'd2,
    RxIncomingRRead = 3'd3,
    RxIncomingAWrite = 3'd4,
    RxIncomingRWrite = 3'd5,
    RxLoop      = 3'd6,
    RxError     = 3'd7
  } rx_e;

  typedef enum logic [2:0]  {
    TxNone      = 3'd0,
    TxTransit   = 3'd1,
    TxOutgoingA = 3'd2,
    TxOutgoingR = 3'd3,
    TxSelfReq   = 3'd4
  } tx_e;

  function automatic int find_max_channel(input int channel[4]);
    int max_value = 0;
    for (int i = 0; i < 4; i++) begin
      if (max_value < channel[i]) max_value = channel[i];
    end
    return max_value;
  endfunction

  typedef struct packed {                                                                                     
    int unsigned          AddrWidth;
    int unsigned          DataWidth;
    int unsigned          RDataWidth;
    int unsigned          IDWidth;
    bit                   UseByteEnable;                                                                              
    bit                   UseOptional;
  } slink_obi_cfg_t;



  function automatic slink_obi_cfg_t slink_obi_cfg(int unsigned AddrWidth, int unsigned DataWidth, int unsigned RDataWidth, int unsigned AIDWidth, int unsigned RIDWidth, bit UseByteEnable = 1, bit UseOptional = 0);
    slink_obi_cfg = '{
      AddrWidth:       AddrWidth,
      DataWidth:       DataWidth,
      RDataWidth:      RDataWidth,
      IDWidth:         AIDWidth > RIDWidth ? AIDWidth : RIDWidth,
      UseByteEnable:   UseByteEnable,
      UseOptional:     UseOptional
    };
  endfunction

endpackage : slink_pkg