# This file is not an active part of the package. This is the code
# that uses the Clang.jl package to wrap Sundials using the headers.

# Find all headers
incpath = joinpath(dirname(@__FILE__), "..", "deps", "usr", "include")
if !isdir(incpath)
  error("Run Pkg.build(\"Sundials\") before trying to wrap C headers.")
end

wdir = joinpath(dirname(@__FILE__), "..", "new")
mkpath(wdir)
cd(wdir)

sundials_names = ["nvector", "sundials", "cvode", "cvodes", "ida", "idas", "kinsol"]
if isdir(joinpath(incpath, "arkode"))
  push!(sundials_names, "arkode")
end
headers = ASCIIString[]
for name in sundials_names
    path = joinpath(incpath, name)
    append!(headers, map(x->joinpath(path, x),
            sort!(convert(Vector{ASCIIString}, readdir(path)))))
end
# @show headers


## Do wrapping using Clang.jl
ENV["JULIAHOME"] = "/Users/jgoldfar/Public/julia/usr/"

using Clang.wrap_c

if (!haskey(ENV, "JULIAHOME"))
  error("Please set JULIAHOME variable to the root of your julia install")
end

clang_includes = map(x->joinpath(ENV["JULIAHOME"], x), [
  "deps/llvm-3.2/build/Release/lib/clang/3.2/include",
  "deps/llvm-3.2/include",
  "deps/llvm-3.2/include",
  "deps/llvm-3.2/build/include/",
  "deps/llvm-3.2/include/"
  ])

# check_use_header(path) = true
# Callback to test if a header should actually be wrapped (for exclusion)
function wrap_header(top_hdr::ASCIIString, cursor_header::ASCIIString)
    !ismatch(r"(_parallel|_impl)\.h$", top_hdr) &&
    !ismatch(r"(_parallel|_impl)\.h$", cursor_header) &&  # don't wrap parallel and implementation definitions
    (basename(dirname(top_hdr)) == basename(dirname(cursor_header))) # don't wrap e.g. nvector in cvode or cvode in cvodes
end
function wrap_cursor(name::ASCIIString, cursor)
    if typeof(cursor) == Clang.cindex.FunctionDecl
        # only wrap API functions
        return ismatch(r"^(CV|KIN|IDA|N_V)", name)
    else
        # skip problematic definitions
        return !ismatch(r"^(ABS|SQRT|EXP)$", name)
    end
end

function julia_file(header::AbstractString)
    src_name = basename(dirname(header))
    if src_name == "sundials"
        src_name = "libsundials" # avoid having both Sundials.jl and sundials.jl
    end
    return string(src_name, ".jl")
end
function library_file(header::AbstractString)
    header_name = basename(header)
    if startswith(header_name, "nvector")
        return "libsundials_nvecserial"
    else
        return string("libsundials_", basename(dirname(header)))
    end
end

clang_extraargs = [
"-D", "__STDC_LIMIT_MACROS", "-D", "__STDC_CONSTANT_MACROS",
"-v"]
context = wrap_c.init(
common_file="types_and_consts.jl",
clang_args = clang_extraargs, clang_diagnostics = true,
clang_includes = [clang_includes; incpath],
header_outputfile = julia_file,
header_library = library_file,
header_wrapped=wrap_header,
cursor_wrapped=wrap_cursor)
context.headers = headers

# 1st arg name to wrapped arg type map
const arg1_name2type = Dict(
    :cvode_mem => :(CVODEMemPtr),
    :kinmem => :(KINMemPtr),
    :kinmemm => :(KINMemPtr), # Sundials typo?
    :ida_mem => :(IDAMemPtr),
    :idaa_mem => :(IDAMemPtr), # Sundials typo?
    :idaadj_mem => :(IDAMemPtr), # Sundials typo?
)

const ctor_return_type = Dict(
    "CVodeCreate" => :(CVODEMemPtr),
    "IDACreate" => :(IDAMemPtr),
    "KINCreate" => :(KINMemPtr)
)

typeify_sundials_pointers(notexpr) = notexpr

function typeify_sundials_pointers(expr::Expr)
    if expr.head == :function &&
        expr.args[1].head == :call
        func_name = string(expr.args[1].args[1])
        if ismatch(r"^(CV|KIN|IDA|N_V)", func_name)
            if ismatch(r"Create$", func_name)
                # create functions return typed pointers
                @assert expr.args[2].args[1].args[2] == :(Ptr{Void})
                expr.args[2].args[1].args[2] = ctor_return_type[func_name]
            elseif length(expr.args[1].args) > 1
                arg1_name = expr.args[1].args[2].args[1]
                arg1_type = expr.args[1].args[2].args[2]
                if arg1_type == :(Ptr{Void}) || arg1_type == :(Ptr{Ptr{Void}})
                    # also check in the ccall list of arg types
                    @assert expr.args[2].args[1].args[3].args[1] == arg1_type
                    arg1_newtype = arg1_name2type[arg1_name]
                    if arg1_type == :(Ptr{Ptr{Void}})
                        # adjust for void** type (for CVodeFree()-like funcs)
                        arg1_newtype = Expr(:curly, :Ref, arg1_newtype)
                    end
                    expr.args[1].args[2].args[2] = arg1_newtype
                    expr.args[2].args[1].args[3].args[1] = arg1_newtype
                end
            end
            if ismatch(r"UserDataB?$", func_name)
                # replace Ptr{Void} with Any to allow passing Julia objects through user data
                for (i, arg_expr) in enumerate(expr.args[1].args)
                    if i > 1 && ismatch(r"^user_dataB?$", string(arg_expr.args[1]))
                        @assert arg_expr.head == :(::) && arg_expr.args[2] == :(Ptr{Void})
                        expr.args[1].args[i].args[2] = :(Any)
                        # replace in ccall list
                        @assert expr.args[2].args[1].args[3].args[i-1] == :(Ptr{Void})
                        expr.args[2].args[1].args[3].args[i-1] = :(Any)
                        break
                    end
                end
            end
        end
    elseif expr.head == :const && expr.args[1].head == :(=) &&
           isa(expr.args[1].args[2], Int)
        # fix integer constants should be Cint
        expr.args[1].args[2] = Expr(:call, :Cint, expr.args[1].args[2])
    end
    expr
end

context.rewriter = function(exprs)
    map(typeify_sundials_pointers, exprs)
end

run(context)
