module Speed

export include
# public functions are @Speed.upper, Speed.poison!([::Module]), Speed.include()

import Base.Meta.isexpr

# this will always be written as the first element of the file
# to check for version changes
VERSION = 7

global ispoisoned = Set{Module}()
global modtimes = Dict{String,Float64}()
function __init__()
    empty!(ispoisoned)
    empty!(modtimes)
end
function poison!(m::Module=current_module())
    push!(ispoisoned,m)
end

macro upper()
    quote
        prev = abspath(Base.source_path(nothing))
        if prev !== nothing
            modtimes[prev] = mtime(prev)
        end
    end
end

#### THIS CODE WORKS AROUND A BUG IN BASE
# https://github.com/JuliaLang/julia/pull/4896
# https://github.com/JuliaLang/julia/issues/308
_replace_dict{T<:Dict}(dest::T, src::T) = ccall(:memcpy, Ptr{Void}, (Ptr{T}, Ptr{T}, Int), &dest, &src, sizeof(src))
const _old_known_lambda_data = Dict()
const _new_known_lambda_data = Dict()
function deserialize(f)
    empty!(_new_known_lambda_data)
    _replace_dict(_old_known_lambda_data, Base.known_lambda_data)
    _replace_dict(Base.known_lambda_data, _new_known_lambda_data)
    try
        return Base.deserialize(f)
    finally
        _replace_dict(Base.known_lambda_data, _old_known_lambda_data)
    end
end
####

function include(filename::String)
    global ispoisoned
    myid() == 1 || return Base.include(filename) # remote handler is not implemented

    prev = Base.source_path(nothing)
    path = abspath(prev === nothing ? filename : joinpath(dirname(prev),filename))
    tls = task_local_storage()
    tls[:SOURCE_PATH] = path

    local c = nothing
    local lno = Array(Int), res = nothing
    lno[] = 0
    try
        cache_path = string(path,'c')
        cm = current_module()
        isfile(path) || error("could not open file $path")
        path_mtime = mtime(path)::Float64
        modtimes[path] = path_mtime
        if cm in ispoisoned
            fail = true
        elseif !isfile(cache_path)
            fail = true
            poison!(cm)
        else
            local cache
            try
                cache = open(cache_path,"r")
                if ((read(cache, Int64) != WORD_SIZE) ||
                    (read(cache, Int64) != Base.ser_version))
                    close(cache)
                    fail = true
                    poisen!(cm)
                else
                    header = deserialize(cache)
                    if (!isa(header,Tuple) ||
                        length(header) != 4 ||
                        (header[1] != OS_NAME) ||
                        (header[2] != VERSION) ||
                        (header[3] != path_mtime) ||
                        (header[4] != get(modtimes, prev, 0.0)))
                        close(cache)
                        fail = true
                        poison!(cm)
                    else
                        fail = false
                    end
                end
            catch e
                try close(cache) end
                fail = true
                poison!(cm)
                warn(e, prefix="Speed.jl WARNING: ", bt=catch_backtrace())
            end
        end
        if !fail
            res = eval_expr(cm, cache, lno)
            close(cache)
        else
            #println("cache miss $path")
            code = parse("quote $(readall(path)) end").value
            rename!(code, symbol(path))
            f = IOBuffer()
            write(f, int64(WORD_SIZE))
            write(f, int64(Base.ser_version))
            serialize(f, (Sys.OS_NAME, VERSION, path_mtime, prev === nothing ? 0.0 : mtime(prev)))
            res = eval_expr(f, cm, code, lno)
            try
                cache = open(cache_path,"w")
                write(cache, takebuf_array(f))
                close(cache)
            catch e
                warn(e, prefix="Speed.jl WARNING: ", bt=catch_backtrace())
            end
        end
    catch e
        println(lno[])
        rethrow(LoadError(path, lno[], e))
    finally
        if prev == nothing
            delete!(tls, :SOURCE_PATH)
        else
            tls[:SOURCE_PATH] = prev
        end
        delete!(modtimes, path)
    end
    return res
end

function eval_expr(f::IO, cm::Module, code::Expr, lno::Array{Int,0}) # serialize
    res = nothing
    for ex in code.args
        if isa(ex,LineNumberNode)
            lno[] = (ex::LineNumberNode).line
            serialize(f, ex)
            continue
        elseif Meta.isexpr(ex,:line)
            lno[] = ex.args[1]
            serialize(f, ex)
            continue
        end
        c = expand(ex)
        if isexpr(c, :const)
            c2 = c.args[1]
            isconst = true
        else
            c2 = c
            isconst = false
        end
        if isexpr(c2, :(=)) && is(c2.args[1],Expr) && c2.args[1].head !== :call
            #for "a = b", but not "a() = b", try to pre-evaluate b
            res = Core.eval(cm, c)
            if !isa(res,Ptr)
                c2 = Expr(c2.head, c2.args[1], res)
                if isconst
                    c = Expr(:const, c2)
                end
            end
            serialize(f, c)
        elseif isexpr(c, :module) && length(c.args) == 3 &&
                isexpr(c.args[3], :block) && isa(c.args[2],Symbol) && isa(c.args[1],Bool)
            res = Core.eval(cm, Expr(:module, c.args[1], c.args[2], quote
                $module_body($f, $(c.args[2]), $(QuoteNode(c)), $lno)
            end))
        else
            serialize(f, c)
            res = Core.eval(cm, c)
        end
    end
    res
end

function eval_expr(cm::Module, f::IO, lno::Array{Int,0}) # deserialize
    res = nothing
    while !eof(f)
        c = deserialize(f)
        if isa(c,LineNumberNode)
            lno[] = (c::LineNumberNode).line
        elseif Meta.isexpr(c,:line)
            lno[] = c.args[1]
        elseif isexpr(c, :compressed_module)
            Core.eval(cm, Expr(:module, c.args[1], c.args[2], quote
                $module_body($(c.args[2]), $(QuoteNode(c)), $lno)
            end))
        else
            res = Core.eval(cm, c)
        end
    end
    res
end


function module_body(f1::IO, cm::Module, m::Expr, lno::Array{Int,0}) # serialize
    f = IOBuffer()
    res = eval_expr(f, cm, m.args[3], lno)
    serialize(f1, Expr(:compressed_module, m.args[1], m.args[2], takebuf_array(f)))
    res
end

function module_body(cm, m::Expr, lno::Array{Int,0}) # deserialize
    return eval_expr(cm, IOBuffer(m.args[3]), lno)
end

rename!(::ANY, fname::Symbol) = nothing
function rename!(e::Expr, fname::Symbol)
    if e.head === :line
        if length(e.args) == 2 && e.args[2] === :none
            e.args[2] = fname
        end
    else
        for a in e.args
            rename!(a, fname)
        end
    end
end

end
