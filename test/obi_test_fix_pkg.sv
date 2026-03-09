


package obi_test_fix_pkg;
    import obi_pkg::*;
    import obi_test::*;
    

    class obi_rand_manager_fixed #(
        // Obi Parameters
        parameter obi_cfg_t    ObiCfg           = ObiDefaultConfig,
        parameter type         obi_a_optional_t = logic,
        parameter type         obi_r_optional_t = logic,
        // Stimuli Parameters
        parameter time         TA               = 2ns,
        parameter time         TT               = 8ns,
        // Manager Parameters
        parameter int unsigned MinAddr          = 32'h0000_0000,
        parameter int unsigned MaxAddr          = 32'hffff_ffff,
        // Wait Parameters
        parameter int unsigned AMinWaitCycles   = 0,
        parameter int unsigned AMaxWaitCycles   = 100,
        parameter int unsigned RMinWaitCycles   = 0,
        parameter int unsigned RMaxWaitCycles   = 100
    ) extends obi_test::obi_rand_manager #(
        .ObiCfg           ( ObiCfg           ),
        .obi_a_optional_t ( obi_a_optional_t ),
        .obi_r_optional_t ( obi_r_optional_t ),
        .TA               ( TA               ),
        .TT               ( TT               ),
        .MinAddr          ( MinAddr          ),
        .MaxAddr          ( MaxAddr          ),
        .AMinWaitCycles   ( AMinWaitCycles   ),
        .AMaxWaitCycles   ( AMaxWaitCycles   ),
        .RMinWaitCycles   ( RMinWaitCycles   ),
        .RMaxWaitCycles   ( RMaxWaitCycles   )
    );

        typedef logic [ObiCfg.AddrWidth-1:0] addr_t;

        function new(
            virtual OBI_BUS_DV #(
                .OBI_CFG          ( ObiCfg           ),
                .obi_a_optional_t ( obi_a_optional_t ),
                .obi_r_optional_t ( obi_r_optional_t )
            ) obi,
            input string name
        );
            super.new(obi, name);
        endfunction

        // Hidden replacement for the buggy upstream send_as()
        task automatic send_as(input int unsigned n_reqs);
            automatic addr_t a_addr;
            automatic logic a_we;
            automatic logic [ObiCfg.DataWidth/8-1:0] a_be;
            automatic logic [ObiCfg.DataWidth-1:0] a_wdata;
            automatic logic [ObiCfg.IdWidth-1:0] a_aid;
            automatic obi_a_optional_t a_optional;

            repeat (n_reqs) begin
                rand_wait(0, 100);

                // Generate random address
                a_addr = $urandom();
                a_we = $urandom() % 2;
                assert(std::randomize(a_be));
                assert(std::randomize(a_wdata));
                assert(std::randomize(a_aid));
                assert(std::randomize(a_optional));

                this.a_queue.push_back(a_addr);
                this.drv.send_a(a_addr, a_we, a_be, a_wdata, a_aid, a_optional);
            end
        endtask

        task automatic run(int unsigned n_reqs);
            $display("Run for Reqs: %0d", n_reqs);
            fork
                this.send_as(n_reqs);
                this.recv_rs(n_reqs);
            join
        endtask

    endclass

endpackage