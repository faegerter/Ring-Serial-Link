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

  function automatic int find_max_channel(input int channel[5]);
    int max_value = 0;
    for (int i = 0; i < 5; i++) begin
      if (max_value < channel[i]) max_value = channel[i];
    end
    return max_value;
  endfunction

  localparam logic [3:0] CFG_REG_SEL = 4'b0000;
endpackage : slink_pkg
