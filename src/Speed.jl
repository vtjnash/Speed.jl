module Speed
export include
import Base.Meta.isexpr
function include(filename::String)
    prev = Base.source_path(nothing)
    path = (prev == nothing) ? abspath(filename) : joinpath(dirname(prev),filename)
    tls = task_local_storage()
    tls[:SOURCE_PATH] = path

    cache_path = string(path,"c")
    cm = current_module()
    local c = nothing, lno::Int = 0
    try
        if isfile(cache_path)
            open(cache_path,"r") do f
                while !eof(f)
                    c = deserialize(f)
                    if isa(c,LineNumberNode)
                        lno = (c::LineNumberNode).line
                    elseif Meta.isexpr(c,:line)
                        lno = c.args[1]
                    else
                        eval(cm, c)
                    end
                end
            end
        else
            code = parse("quote $(readall(path)) end").value
            rename(code, symbol(path))
            open(cache_path,"w") do f
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
                        eval(cm, c)
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
    end
    
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
