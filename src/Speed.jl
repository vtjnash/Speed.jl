module Speed

export include
# public functions are @Speed.upper, Speed.poison!([::Module]), Speed.include()

import Base.Meta.isexpr

# this will always be written as the first element of the file
# to check for version changes
VERSION = 0

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

function include(filename::String)
    global ispoisoned
    myid() == 1 || return Base.include(filename) # remote handler is not implemented

    prev = Base.source_path(nothing)
    path = abspath(prev === nothing ? filename : joinpath(dirname(prev),filename))
    tls = task_local_storage()
    tls[:SOURCE_PATH] = path

    local c = nothing, lno::Int = 0, res = nothing
    try
        cache_path = string(path,'c',Base.ser_version::Int)
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
            cache = open(cache_path,"r")
            if ((deserialize(cache) != VERSION) ||
                (deserialize(cache)::Float64 != path_mtime) ||
                (deserialize(cache)::Float64 != get(modtimes, prev, 0.0)))
                close(cache)
                fail = true
                poison!(cm)
            else
                fail = false
            end
        end
        if !fail
            f = cache::IOStream
            while !eof(f)
                c = deserialize(f)
                if isa(c,LineNumberNode)
                    lno = (c::LineNumberNode).line
                elseif Meta.isexpr(c,:line)
                    lno = c.args[1]
                else
                    res = eval(cm, c)
                end
            end
            close(f)
        else
            #println("cache miss $path")
            code = parse("quote $(readall(path)) end").value
            rename(code, symbol(path))
            open(cache_path,"w") do f
                serialize(f, VERSION)
                serialize(f, path_mtime)
                serialize(f, prev === nothing ? 0.0 : mtime(prev))
                for c in code.args
                    if isa(c,LineNumberNode)
                        lno = (c::LineNumberNode).line
                    elseif Meta.isexpr(c,:line)
                        lno = c.args[1]
                    else
                        c = macroexpand(c)
                    end
                    if isexpr(c, :const)
                        c2 = c.args[1]
                        isconst = true
                    else
                        c2 = c
                        isconst = false
                    end
                    if isexpr(c2, :(=)) && is(c2.args[1],Expr) && c2.args[1].head !== :call
                        #for "a = b", but not "a() = b", try to pre-evaluate b
                        try
                            res = eval(cm, c)
                        catch
                            serialize(f,c)
                            rethrow()
                        end
                        if !isa(res,Ptr)
                            c2 = Expr(c2.head, c2.args[1], res)
                            if isconst
                                c = Expr(:const, c2)
                            end
                        end
                        serialize(f, c)
                    else
                        serialize(f, c)
                        res = eval(cm, c)
                    end
                end
            end
        end
    catch e
        rethrow(LoadError(path, lno, e))
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

rename(::ANY, fname::Symbol) = nothing
function rename(e::Expr, fname::Symbol)
    if e.head === :line
        if length(e.args) == 2 && e.args[2] === :none
            e.args[2] = fname
        end
    else
        for a in e.args
            rename(a, fname)
        end
    end
end

end
