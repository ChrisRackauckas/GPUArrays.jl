__precompile__(true)
module GPUArrays

include("abstractarray.jl")
include("abstract_gpu_interface.jl")
include("base.jl")
include("construction.jl")
include("blas.jl")
include("broadcast.jl")
include("devices.jl")
include("heuristics.jl")
include("indexing.jl")
include("linalg.jl")
include("mapreduce.jl")
include("vectors.jl")
include("testsuite/testsuite.jl")

export GPUArray, gpu_call, thread_blocks_heuristic
export linear_index, @linearidx, @cartesianidx

end # module
