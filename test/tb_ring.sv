// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Author: Llorenç Muela Hausmann <lmuela@ethz.ch>
// Author: Fabian Aegerter <faegerter@ethz.ch>


`define OBI_CONNECT_MANAGER(_if, _req, _rsp) \
    assign _req.a.addr       = _if.addr; \
    assign _req.a.we         = _if.we; \
    assign _req.a.be         = _if.be; \
    assign _req.a.wdata      = _if.wdata; \
    assign _req.a.aid        = _if.aid; \
    assign _req.a.a_optional = _if.a_optional; \
    assign _req.req          = _if.req; \
    assign _if.gnt           = _rsp.gnt; \
    assign _if.rvalid        = _rsp.rvalid; \
    assign _if.rdata         = _rsp.r.rdata; \
    assign _if.rid           = _rsp.r.rid; \
    assign _if.err           = _rsp.r.err; \
    assign _if.r_optional    = _rsp.r.r_optional;

`define OBI_CONNECT_SUBORDINATE(_if, _req, _rsp) \
    assign _if.addr          = _req.a.addr; \
    assign _if.we            = _req.a.we; \
    assign _if.be            = _req.a.be; \
    assign _if.wdata         = _req.a.wdata; \
    assign _if.aid           = _req.a.aid; \
    assign _if.a_optional    = _req.a.a_optional; \
    assign _if.req           = _req.req; \
    assign _rsp.gnt          = _if.gnt; \
    assign _rsp.rvalid       = _if.rvalid; \
    assign _rsp.r.rdata      = _if.rdata; \
    assign _rsp.r.rid        = _if.rid; \
    assign _rsp.r.err        = _if.err; \
    assign _rsp.r.r_optional = _if.r_optional;


module tb_ring;

    import slink_reg_pkg::*;
    import slink_pkg::*;
    import obi_pkg::*;
    import obi_test_fix_pkg::*;

    `include "obi/typedef.svh"
    `include "obi/assign.svh"
    `include "slink_addrmap.svh"
    `include "../include/slink_obi/typedef.svh"
endmodule