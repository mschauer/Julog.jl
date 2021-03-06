"Parse Julog terms using Prolog-like syntax."
function parse_term(expr)
    if isa(expr, Union{String,Number,Enum,Bool})
        # Strings, numbers, enums and bools are automatically constants
        return :(Const($expr))
    elseif isa(expr, Symbol)
        if expr == :_
            # Underscores are wildcards, parsed to variables with new names
            return Expr(:call, Var, Meta.quot(gensym(expr)))
        elseif isuppercase(string(expr)[1]) || string(expr)[1] == "_"
            # Initial uppercase / underscored symbols are parsed to variables
            return Expr(:call, Var, Meta.quot(expr))
        else
            # Everything else is parsed to a constant
            return Expr(:call, Const, Meta.quot(expr))
        end
    elseif isa(expr, Expr) && expr.head == :tuple
        # Fully evaluated tuples are valid constants
        return :(Const(eval($expr)))
    elseif isa(expr, Expr) && expr.head == :vect
        # Parse vector as Prolog style list
        return parse_list(expr.args)
    elseif isa(expr, Expr) && expr.head == :$
        # Evaluate interpolated expression as Const within scope of caller
        val = expr.args[1]
        return :(Const($(esc(val))))
    elseif isa(expr, Expr) && expr.head == :call
        # A compound term comprises its name (functor) and arguments
        name = Meta.quot(expr.args[1])
        args = [parse_term(e) for e in expr.args[2:end]]
        return :(Compound($name, [$(args...)]))
    elseif isa(expr, QuoteNode)
        # Evaluate quoted expression within scope of caller
        val = expr.value
        return :($(esc(val)))
    else
        dump(expr)
        error("syntax error in Julog term at $expr")
    end
end

"Parse arguments of vector using Prolog-style list syntax."
function parse_list(args)
    if (length(args) > 0 && isa(args[end], Expr) &&
        args[end].head == :call && args[end].args[1] == :|)
        # Handle [... | Tail] syntax for last element
        tail = parse_term(args[end].args[3])
        pretail = parse_term(args[end].args[2])
        tail = :(Compound(:c, [$pretail, $tail]))
        args = args[1:end-1]
    else
        # Initialize tail to empty list
        tail = :(Compound(:cend, []))
    end
    # Recursively build list using :c (short for cons)
    elts = [parse_term(a) for a in args]
    for e in reverse(elts)
        tail = :(Compound(:c, [$e, $tail]))
    end
    return tail
end

"Parse body of Julog clause using Prolog-like syntax, with '&' replacing ','."
function parse_body(expr)
    if expr == true
        return []
    elseif isa(expr, Symbol)
        return [parse_term(expr)]
    elseif isa(expr, Expr) && expr.head == :call
        if expr.args[1] == :&
            # '&' is left-associative, so we descend the parse tree accordingly
            return [parse_body(expr.args[2]); parse_term(expr.args[3])]
        else
            return [parse_term(expr)]
        end
    else
        dump(expr)
        error("syntax error in body of Julog clause at $expr")
    end
end

"Parse Julog expression using Prolog-like syntax. '<<=' replaces ':-' in clauses."
function parse_julog(expr)
    if isa(expr, Expr) && expr.head == :<<=
        head = parse_term(expr.args[1])
        body = parse_body(expr.args[2])
        return :(Clause($head, [$(body...)]))
    elseif isa(expr, Expr) && expr.head == :vect
        exprs = [parse_julog(a) for a in expr.args]
        return :([$(exprs...)])
    else
        return parse_term(expr)
    end
end

"Macro that parses and return Julog expressions."
macro julog(expr)
    return parse_julog(expr)
end

"Macro that parses Julog substitutions, e.g. {X => hello, Y => world}."
macro varsub(expr)
    if !(isa(expr, Expr) && expr.head == :braces)
        error("Invalid format for Julog substitutions.")
    end
    vars = [Var(a.args[2]) for a in expr.args]
    terms = [eval(parse_term(a.args[3])) for a in expr.args]
    return Subst(v => t for (v,t) in zip(vars, terms))
end

"Convert Prolog string to list of Julog strings."
function prolog_to_julog(str::String)
    clauses = String[]
    # Match each clause (being careful to handle periods in lists + floats)
    for m in eachmatch(r"((?:\d\.\d+|[^\.]|\.\()*)\.\s*", str)
        clause = m.captures[1]
        # Replace cuts, negations and implications
        clause = replace(clause, "!" => "cut")
        clause = replace(clause, "\\+" => "!")
        clause = replace(clause, "->" => "=>")
        clause = replace(clause, ".(" => "c(")
        # Try to match to definite clause
        m = match(r"(.*):-(.*)", clause)
        if m == nothing
            # Push fact on to list of clauses
            clause = clause * " <<= true"
            push!(clauses, clause)
            continue
        end
        # Handle definite clauses
        head, body = m.captures[1:2]
        # Handle disjunctions within the body
        for bd in split(body, ";")
            # Handle conjuctions within body (find commas outside of brackets)
            br_count = 0
            commas = [0]
            for (idx, chr) in enumerate(bd)
                if (chr == '(') br_count += 1
                elseif (chr == ')') br_count -= 1
                elseif (chr == ',') && br_count == 0 push!(commas, idx) end
            end
            push!(commas, length(bd)+1)
            terms = [strip(bd[a+1:b-1]) for (a, b) in
                     zip(commas[1:end-1], commas[2:end])]
            subclause = strip(head) * " <<= " * join(terms, " & ")
            push!(clauses, subclause)
        end
    end
    return clauses
end

"Parse Julog expression from string using standard Prolog syntax."
function parse_prolog(str::String)
    strs = prolog_to_julog(str)
    exprs = [@julog($(Meta.parse(s))) for s in strs]
    return exprs
end

"Write list of Julog clauses to Prolog string."
function write_prolog(clauses::Vector{Clause})
    str = ""
    for clause in clauses
        clause = repr(clause)
        clause = replace(clause, "!" => "\\+")
        clause = replace(clause, "=>" => "->")
        clause = replace(clause, " &" => ",")
        clause = replace(clause, "<<=" => ":-")
        str = str * clause * ".\n"
    end
    return str
end

"Macro that parses Prolog programs as strings and returns Julog clauses."
macro prolog(str::String)
    strs = prolog_to_julog(str)
    exprs = [parse_julog(Meta.parse(s)) for s in strs]
    return :([$(exprs...)])
end
