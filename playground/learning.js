/* Local, editorial language help. This is lexical guidance, not type inference. */
window.TeslLearning = (() => {
  const guide = 'https://github.com/mtonnberg/tesl/blob/main/manual/';
  const entries = {
    fact: ['fact: give a rule a name', 'A fact names something your program needs to know about particular values. InWorkspace invoice workspace means this invoice belongs to this workspace. The declaration alone checks nothing: checkWorkspace must establish it. Keeping that evidence in the function signature lets the compiler catch callers that skip the check. The check body is trusted code: you still need to implement and test the rule correctly.', 'best-practices.md#proof-management'],
    check: ['check: validate once, carry the result', 'A check runs validation. Its successful branch returns a value with evidence attached; its failure branch rejects the input. In the invoice example, comparing the workspace fields establishes InWorkspace for those particular values. Downstream functions can require that evidence instead of relying on every caller to remember validation.', 'best-practices.md#proof-management'],
    ':::': ['::: means “with evidence of this rule”', 'The value on the left carries the fact on the right. Invoice ::: InWorkspace invoice workspace is still an invoice, with evidence about that invoice and workspace. Passing an unchecked value does not satisfy the signature. It does not authenticate a workspace: a service must obtain that identity from trusted authentication.', 'best-practices.md#proof-management'],
    requires: ['requires: make permissions visible', 'A requires clause lists capabilities a function needs, such as database reads or writes. The compiler checks these declarations against the operations and calls in the body. This makes privileged effects visible at the function boundary; it does not replace authentication or a correct authorization policy.', 'best-practices.md'],
    record: ['record: related values, with named fields', 'A record describes the fields a value must contain. Invoice has an id and a workspace. A record type alone does not prove that a particular user may access it; that separate rule is what the workspace check expresses.', 'MANUAL.md'],
    handler: ['handler: code that answers a request', 'A handler implements an HTTP operation. The API declares the route and response type; the server connects the API to its handlers. The playground checks these declarations. To send a real HTTP request, save the server example and run it locally.', 'MANUAL.md'],
    api: ['api: describe the HTTP contract', 'An API declaration defines routes and their input and output types. Tesl can generate client code from that contract. Pair it with handlers and a server to implement the routes, then run an App locally to listen for requests.', 'MANUAL.md'],
    server: ['server: connect routes to handlers', 'A server connects an API declaration to its implementation. An App supplies the server and listening port. This page compiles the source but does not start a listener; the run guide shows the next step.', 'MANUAL.md'],
    main: ['main: start the application', 'The main function returns an App with the database configuration, API server and port. The Hello HTTP example uses an empty in-memory database, so it needs no separate database service. Run it with tesl run HelloServer.tesl.', 'MANUAL.md'],
    test: ['test: exercise a concrete case', 'A test documents an expected outcome and runs it against your code. The invoice example tests both a matching workspace and a rejected mismatch. The browser checks test code but does not execute it; run the tests locally. Compiler checks and runtime examples answer different questions.', 'MANUAL.md'],
    import: ['import: bring a building block into scope', 'An import makes declarations from another module available. exposing lists the names you use. Builtin search can provide the import to copy. This browser includes Tesl.* modules; other local files require a local project.', 'MANUAL.md']
  };
  function explain(source, selection) {
    const start = selection.start, end = selection.end;
    const lineStart = source.lastIndexOf('\n', start - 1) + 1;
    const lineEnd = source.indexOf('\n', start);
    const line = source.slice(lineStart, lineEnd < 0 ? source.length : lineEnd);
    const selected = source.slice(start, end).trim();
    const tokenAtCursor = (source.slice(0, start).match(/[A-Za-z_:]*$/)?.[0] || '') + (source.slice(start).match(/^[A-Za-z_:]*/)?.[0] || '');
    const candidates = [selected, tokenAtCursor, ...line.match(/:::|\b(?:fact|check|requires|record|handler|api|server|main|test|import)\b/g) || []];
    const key = candidates.find(word => Object.hasOwn(entries, word));
    if (!key) return { title: 'Choose a language feature to explore', body: 'Place the cursor on fact, check, :::, requires, record, handler, api, server, main, test or import, then choose Explain this. You can also right-click a line number. For function names and signatures, use Search builtins.', link: 'lessons.html' };
    const [title, body, path] = entries[key];
    return { title, body, link: guide + path };
  }
  return { explain };
})();
