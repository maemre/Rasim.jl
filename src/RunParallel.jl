#!/usr/bin/env julia -p 4

@everywhere using Params, Rasim

pmap(Rasim.run_whole_simulation, shuffle(genparams()))