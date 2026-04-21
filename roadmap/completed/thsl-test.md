It should be easy to write test in tesl and the test philosophy should be clear, ergonomic and opinionated.

Goals: Tesl should have
- a streamlined and easy to use way to write propertybased tests (aka fuzzy testing)
- Doctests as a first class citizen (both with examples and prop-tests)
- api-tests with a proper database as a first class citizen
- Arbitraries and generators should be inferred from the codecs with the possibility to easily tweak the generation in each test (for example only generate strings longer than 5 characters should be possible to do inline with simple where len(s) > 5 or something)
- Mutationtests should be built in and a first class citizen and be run when you run the normal tests
- A failing testresult should provide good guesses for a fix and/or give a human/ai a constructive way forward
- The framework should help a developer to push from comment -> unittest -> proptest -> type in constructive and pedagogical way
