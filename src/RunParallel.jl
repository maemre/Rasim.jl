#!/usr/bin/env julia -p 3

@everywhere using Params, Rasim

pmap(Rasim.run_whole_simulation, genparams())