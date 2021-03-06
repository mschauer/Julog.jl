# Test the natural numbers and addition
clauses = @julog [
    nat(0) <<= true,
    nat(s(N)) <<= nat(N),
    add(0, Y, Y) <<= true,
    add(s(X), Y, s(Z)) <<= add(X, Y, Z)
]

# Is 1 a natural number?
sat, subst = resolve(@julog(nat(s(0))), clauses)
@test sat == true

# Is 5 a natural number?
sat, subst = resolve(@julog(nat(s(s(s(s(s(0))))))), clauses)
@test sat == true

# Is 1 + 1 = 2?
sat, subst = resolve(@julog(add(s(0), s(0), s(s(0)))), clauses)
@test sat == true

# What are all the ways to add up to 3?
sat, subst = resolve(@julog(add(A, B, s(s(s(0))))), clauses)
subst = Set(subst)
@test @varsub({A => 0, B => s(s(s(0)))}) in subst
@test @varsub({A => s(0), B => s(s(0))}) in subst
@test @varsub({A => s(s(0)), B => s(0)}) in subst
@test @varsub({A => s(s(s(0))), B => 0}) in subst
