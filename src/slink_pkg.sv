// Copyright 2022 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Author: Tim Fischer <fischeti@iis.ee.ethz.ch>

/// A simple package for common serial link types and functions
package slink_pkg;

  typedef enum logic [1:0]  {
    TagIdle = 2'd0,
    TagA    = 2'd1,
    TagR    = 2'd2
  } tag_e;

  typedef enum logic [2:0]  {
    RxNone      = 3'd0,
    RxTransit   = 3'd1,
    RxIncomingA = 3'd2,
    RxIncomingR = 3'd3,
    RxLoop      = 3'd4,
    RxError     = 3'd5
  } rx_e;

  typedef enum logic [1:0]  {
    TxNone      = 2'd0,
    TxTransit   = 2'd1,
    TxOutgoingA = 2'd2,
    TxOutgoingR = 2'd3
  } tx_e;

  function automatic int find_max_channel(input int channel[2]);
    int max_value = 0;
    for (int i = 0; i < 2; i++) begin
      if (max_value < channel[i]) max_value = channel[i];
    end
    return max_value;
  endfunction

endpackage : slink_pkg
