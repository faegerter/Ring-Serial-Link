`ifndef SLINK_OBI_MACROS_SVH
`define SLINK_OBI_MACROS_SVH

`define SLINK_TYPEDEF_ALL(cfg, a_optional_t, r_optional_t)                     \
  localparam bit IncBe   = !cfg.BeFull;                                        \
  localparam bit IncAid  =  cfg.IdWidth > 0;                                   \
  localparam bit IncAopt = cfg.OptionalCfg.UseAtop                ||           \
                           cfg.OptionalCfg.UseMemtype             ||           \
                           cfg.OptionalCfg.UseProt                ||           \
                           cfg.OptionalCfg.UseDbg                 ||           \
                           (cfg.OptionalCfg.AUserWidth > 0)       ||           \
                           (cfg.OptionalCfg.WUserWidth > 0)       ||           \
                           (cfg.OptionalCfg.MidWidth   > 0)       ||           \
                           (cfg.OptionalCfg.AChkWidth  > 0);                   \
  localparam bit IncRid  =  cfg.IdWidth > 0;                                   \
  localparam bit IncRopt = (cfg.OptionalCfg.RUserWidth > 0)       ||           \
                           (cfg.OptionalCfg.RChkWidth  > 0);                   \
  localparam int unsigned AChanReadW  =                                        \
      cfg.AddrWidth                                                            \
    + (IncBe   ? cfg.DataWidth/8     : 0)                                      \
    + (IncAid  ? cfg.IdWidth         : 0)                                      \
    + (IncAopt ? $bits(a_optional_t) : 0);                                     \
  localparam int unsigned AChanWriteW =                                        \
      cfg.AddrWidth                                                            \
    + cfg.DataWidth                                                            \
    + (IncBe   ? cfg.DataWidth/8     : 0)                                      \
    + (IncAid  ? cfg.IdWidth         : 0)                                      \
    + (IncAopt ? $bits(a_optional_t) : 0);                                     \
  localparam int unsigned RChanReadW  =                                        \
      cfg.DataWidth                                                            \
    + 1                                                                        \
    + (IncRid  ? cfg.IdWidth         : 0)                                      \
    + (IncRopt ? $bits(r_optional_t) : 0);                                     \
  localparam int unsigned RChanWriteW =                                        \
      1                                                                        \
    + (IncRid  ? cfg.IdWidth         : 0)                                      \
    + (IncRopt ? $bits(r_optional_t) : 0);                                     \
  typedef logic [AChanReadW-1:0]  a_chan_read_t;                               \
  typedef logic [AChanWriteW-1:0] a_chan_write_t;                              \
  typedef logic [RChanReadW-1:0]  r_chan_read_t;                               \
  typedef logic [RChanWriteW-1:0] r_chan_write_t;

`endif // SLINK_OBI_MACROS_SVH