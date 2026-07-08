(if deemed a good idea and worthy to have as a first class language citizen)

We should have great support for units (money, lenght, time, volume, etc). Since that is a common source of bugs (confusing km/h with m/s or just two different units all together).
(We have "solved" time, partially, already but did not realize that it was just an instance of a class of units)

Libraries in different languages has already solved this nicely so we should be able to take a lot of inspiration form them (adding the Tesl twist with heavy use of proofs on top of it).

This would also solve another major headache we have; LLMs get really confused when given units and starts hallucinating really fast.

All different types should be checked at compiletime to minimize runtime bugs and leverage our proof system as much as possible. The json decoded value should aid llms to understand the value and minimize hallucinations.

Inspirational libraries (may or not be a good fit for us):
- https://pypi.org/project/unitpy/
- https://pint.readthedocs.io/en/stable/user/defining-quantities.html
- https://package.elm-lang.org/packages/ianmackenzie/elm-units/latest/
- https://hackage.haskell.org/package/units
- https://github.com/goldfirere/units
- https://hackage.haskell.org/package/units-defs
- https://package.elm-lang.org/packages/Chadtech/elm-money/latest/
- https://hackage.haskell.org/package/currency
- https://github.com/carlospalol/money