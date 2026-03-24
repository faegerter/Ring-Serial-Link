// ---------------------------------------------------------------------------
// Pack: OBI channel → flat serial struct
// ---------------------------------------------------------------------------

function automatic a_chan_read_t pack_a_chan_read(input a_chan_t ch);
    automatic int unsigned o = 0;
    pack_a_chan_read = '0;
    pack_a_chan_read[o +: ObiCfg.AddrWidth] = ch.addr; o += ObiCfg.AddrWidth;
    if (IncBe)   begin pack_a_chan_read[o +: ObiCfg.DataWidth/8]     = ch.be;         o += ObiCfg.DataWidth/8;     end
    if (IncAid)  begin pack_a_chan_read[o +: ObiCfg.IdWidth]         = ch.aid;        o += ObiCfg.IdWidth;         end
    if (IncAopt) begin pack_a_chan_read[o +: $bits(a_optional_t)]    = ch.a_optional; o += $bits(a_optional_t);    end
endfunction

function automatic a_chan_write_t pack_a_chan_write(input a_chan_t ch);
    automatic int unsigned o = 0;
    pack_a_chan_write = '0;
    pack_a_chan_write[o +: ObiCfg.AddrWidth]  = ch.addr;  o += ObiCfg.AddrWidth;
    pack_a_chan_write[o +: ObiCfg.DataWidth]  = ch.wdata; o += ObiCfg.DataWidth;
    if (IncBe)   begin pack_a_chan_write[o +: ObiCfg.DataWidth/8]    = ch.be;         o += ObiCfg.DataWidth/8;     end
    if (IncAid)  begin pack_a_chan_write[o +: ObiCfg.IdWidth]        = ch.aid;        o += ObiCfg.IdWidth;         end
    if (IncAopt) begin pack_a_chan_write[o +: $bits(a_optional_t)]   = ch.a_optional; o += $bits(a_optional_t);    end
endfunction

function automatic r_chan_read_t pack_r_chan_read(input r_chan_t ch);
    automatic int unsigned o = 0;
    pack_r_chan_read = '0;
    pack_r_chan_read[o +: ObiCfg.DataWidth]   = ch.rdata; o += ObiCfg.DataWidth;
    pack_r_chan_read[o]                        = ch.err;   o += 1;
    if (IncRid)  begin pack_r_chan_read[o +: ObiCfg.IdWidth]         = ch.rid;        o += ObiCfg.IdWidth;         end
    if (IncRopt) begin pack_r_chan_read[o +: $bits(r_optional_t)]    = ch.r_optional; o += $bits(r_optional_t);    end
endfunction

function automatic r_chan_write_t pack_r_chan_write(input r_chan_t ch);
    automatic int unsigned o = 0;
    pack_r_chan_write = '0;
    pack_r_chan_write[o] = ch.err; o += 1;
    if (IncRid)  begin pack_r_chan_write[o +: ObiCfg.IdWidth]        = ch.rid;        o += ObiCfg.IdWidth;         end
    if (IncRopt) begin pack_r_chan_write[o +: $bits(r_optional_t)]   = ch.r_optional; o += $bits(r_optional_t);    end
endfunction

// ---------------------------------------------------------------------------
// Unpack: flat serial struct → OBI channel
// Missing fields default to 0, except be which defaults to '1 (BeFull)
// ---------------------------------------------------------------------------

function automatic a_chan_t unpack_a_chan_read(input a_chan_read_t raw);
    automatic int unsigned o = 0;
    unpack_a_chan_read         = '0;
    unpack_a_chan_read.we      = 1'b0;
    unpack_a_chan_read.wdata   = '0;
    unpack_a_chan_read.be      = '1;           // default: all byte enables active
    unpack_a_chan_read.addr    = raw[o +: ObiCfg.AddrWidth]; o += ObiCfg.AddrWidth;
    if (IncBe)   begin unpack_a_chan_read.be         = raw[o +: ObiCfg.DataWidth/8];     o += ObiCfg.DataWidth/8;     end
    if (IncAid)  begin unpack_a_chan_read.aid        = raw[o +: ObiCfg.IdWidth];         o += ObiCfg.IdWidth;         end
    if (IncAopt) begin unpack_a_chan_read.a_optional = raw[o +: $bits(a_optional_t)];    o += $bits(a_optional_t);    end
endfunction

function automatic a_chan_t unpack_a_chan_write(input a_chan_write_t raw);
    automatic int unsigned o = 0;
    unpack_a_chan_write         = '0;
    unpack_a_chan_write.we      = 1'b1;
    unpack_a_chan_write.be      = '1;          // default: all byte enables active
    unpack_a_chan_write.addr    = raw[o +: ObiCfg.AddrWidth];  o += ObiCfg.AddrWidth;
    unpack_a_chan_write.wdata   = raw[o +: ObiCfg.DataWidth];  o += ObiCfg.DataWidth;
    if (IncBe)   begin unpack_a_chan_write.be         = raw[o +: ObiCfg.DataWidth/8];    o += ObiCfg.DataWidth/8;     end
    if (IncAid)  begin unpack_a_chan_write.aid        = raw[o +: ObiCfg.IdWidth];        o += ObiCfg.IdWidth;         end
    if (IncAopt) begin unpack_a_chan_write.a_optional = raw[o +: $bits(a_optional_t)];   o += $bits(a_optional_t);    end
endfunction

function automatic r_chan_t unpack_r_chan_read(input r_chan_read_t raw);
    automatic int unsigned o = 0;
    unpack_r_chan_read            = '0;
    unpack_r_chan_read.rdata      = raw[o +: ObiCfg.DataWidth]; o += ObiCfg.DataWidth;
    unpack_r_chan_read.err        = raw[o];                      o += 1;
    if (IncRid)  begin unpack_r_chan_read.rid        = raw[o +: ObiCfg.IdWidth];         o += ObiCfg.IdWidth;         end
    if (IncRopt) begin unpack_r_chan_read.r_optional = raw[o +: $bits(r_optional_t)];    o += $bits(r_optional_t);    end
endfunction

function automatic r_chan_t unpack_r_chan_write(input r_chan_write_t raw);
    automatic int unsigned o = 0;
    unpack_r_chan_write            = '0;
    unpack_r_chan_write.rdata      = '0;
    unpack_r_chan_write.err        = raw[o]; o += 1;
    if (IncRid)  begin unpack_r_chan_write.rid        = raw[o +: ObiCfg.IdWidth];        o += ObiCfg.IdWidth;         end
    if (IncRopt) begin unpack_r_chan_write.r_optional = raw[o +: $bits(r_optional_t)];   o += $bits(r_optional_t);    end
endfunction