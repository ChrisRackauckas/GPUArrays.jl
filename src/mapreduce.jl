import Base: any, count, countnz

#############################
# reduce
# functions in base implemented with a direct loop need to be overloaded to use mapreduce
any(pred, A::GPUArray) = Bool(mapreduce(pred, |, Cint(0), (u)))
count(pred, A::GPUArray) = Int(mapreduce(pred, +, UInt32(0), A))
countnz(A::GPUArray) = Int(mapreduce(x-> x != 0, +, UInt32(0), A))
countnz(A::GPUArray, dim) = Int(mapreducedim(x-> x != 0, +, UInt32(0), A, dim))


# hack to get around of fetching the first element of the GPUArray
# as a startvalue, which is a bit complicated with the current reduce implementation
function startvalue(f, T)
    error("Please supply a starting value for mapreduce. E.g: mapreduce($f, $op, 1, A)")
end
startvalue(::typeof(+), T) = zero(T)
startvalue(::typeof(*), T) = one(T)
startvalue(::typeof(Base.scalarmin), T) = typemax(T)
startvalue(::typeof(Base.scalarmax), T) = typemin(T)

# TODO widen and support Int64 and use Base.r_promote_type
gpu_promote_type(op, ::Type{T}) where {T} = T
gpu_promote_type(op, ::Type{T}) where {T<:Base.WidenReduceResult} = T
gpu_promote_type(::typeof(+), ::Type{T}) where {T<:Base.WidenReduceResult} = T
gpu_promote_type(::typeof(*), ::Type{T}) where {T<:Base.WidenReduceResult} = T
gpu_promote_type(::typeof(+), ::Type{T}) where {T<:Number} = typeof(zero(T)+zero(T))
gpu_promote_type(::typeof(*), ::Type{T}) where {T<:Number} = typeof(one(T)*one(T))
gpu_promote_type(::typeof(Base.scalarmax), ::Type{T}) where {T<:Base.WidenReduceResult} = T
gpu_promote_type(::typeof(Base.scalarmin), ::Type{T}) where {T<:Base.WidenReduceResult} = T
gpu_promote_type(::typeof(max), ::Type{T}) where {T<:Base.WidenReduceResult} = T
gpu_promote_type(::typeof(min), ::Type{T}) where {T<:Base.WidenReduceResult} = T

function Base.mapreduce(f::Function, op::Function, A::GPUArray{T, N}) where {T, N}
    OT = gpu_promote_type(op, T)
    v0 = startvalue(op, OT) # TODO do this better
    mapreduce(f, op, v0, A)
end
function acc_mapreduce end
function Base.mapreduce(f, op, v0, A::GPUArray, B::GPUArray, C::Number)
    acc_mapreduce(f, op, v0, A, (B, C))
end
function Base.mapreduce(f, op, v0, A::GPUArray, B::GPUArray)
    acc_mapreduce(f, op, v0, A, (B,))
end
function Base.mapreduce(f, op, v0, A::GPUArray)
    acc_mapreduce(f, op, v0, A, ())
end


function mapreducedim_kernel(state, f, op, R::AbstractArray{T1, N}, A::AbstractArray{T, N}, slice_size, sizeA, dim) where {T1, T, N}
    ilin = UInt32(linear_index(state))
    ilin > length(R) && return
    accum = zero(T1)
    @inbounds for i = UInt32(1):slice_size
        idx = N == dim ? (ilin, i) : (i, ilin)
        i2d = gpu_sub2ind(sizeA, idx)
        accum = op(accum, f(A[i2d]))
    end
    R[ilin] = accum
    return
end
function Base._mapreducedim!(f, op, R::GPUArray, A::GPUArray)
    sizeR = size(R)
    if all(x-> x == 1, sizeR)
        x = mapreduce(f, op, A)
        copy!(R, reshape([x], sizeR))
        return R
    end
    @assert count(x-> x == 1, sizeR) == (ndims(R) - 1) "Not implemented"
    dim = findfirst(x-> x == 1, sizeR)
    slice_size = size(A, dim)
    gpu_call(mapreducedim_kernel, R, (f, op, R, A, UInt32(slice_size), UInt32.(size(A)), UInt32(dim)))
    return R
end

for i = 0:10
    args = ntuple(x-> Symbol("arg_", x), i)
    fargs = ntuple(x-> :(broadcast_index($(args[x]), length, global_index)), i)
    @eval begin
        # http://developer.amd.com/resources/articles-whitepapers/opencl-optimization-case-study-simple-reductions/
        function reduce_kernel(state, f, op, v0::T, A, ::Val{LMEM}, result, $(args...)) where {T, LMEM}
            ui0 = UInt32(0); ui1 = UInt32(1); ui2 = UInt32(2)
            tmp_local = @LocalMemory(state, T, LMEM)
            global_index = linear_index(state)
            acc = v0
            # # Loop sequentially over chunks of input vector
            while global_index <= length(A)
                element = f(A[global_index], $(fargs...))
                acc = op(acc, element)
                global_index += global_size(state)
            end
            # Perform parallel reduction
            local_index = threadidx_x(state) - ui1
            tmp_local[local_index + ui1] = acc
            synchronize_threads(state)

            offset = blockdim_x(state) ÷ ui2
            while offset > ui0
                if (local_index < offset)
                    other = tmp_local[local_index + offset + ui1]
                    mine = tmp_local[local_index + ui1]
                    tmp_local[local_index + ui1] = op(mine, other)
                end
                synchronize_threads(state)
                offset = offset ÷ ui2
            end
            if local_index == ui0
                result[blockidx_x(state)] = tmp_local[ui1]
            end
            return
        end
    end

end

to_cpu(x) = x
to_cpu(x::GPUArray) = Array(x)

function acc_mapreduce(
        f, op, v0::OT, A::GPUArray{T, N}, rest::Tuple
    ) where {T, OT, N}
    dev = device(A)
    blocksize = 80
    threads = 256
    if length(A) <= blocksize * threads
        args = zip(Array(A), to_cpu.(rest)...)
        return mapreduce(x-> f(x...), op, v0, args)
    end
    out = similar(A, OT, (blocksize,))
    fill!(out, v0)
    args = (f, op, v0, A, Val{threads}(), out, rest...)
    gpu_call(reduce_kernel, A, args, ((blocksize,), (threads,)))
    reduce(op, Array(out))
end
