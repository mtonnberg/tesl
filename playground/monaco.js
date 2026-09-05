/* Optional desktop editing component. No language rules are reimplemented here:
   compiler diagnostics/fixes and the shared builtin index supply the services. */
import * as monaco from 'monaco-editor/editor/editor.api.js';
import './node_modules/monaco-editor/esm/vs/base/browser/ui/codicons/codicon/codicon.css';
import './node_modules/monaco-editor/esm/vs/base/browser/ui/codicons/codicon/codicon-modifiers.css';
import 'monaco-editor/editor/browser/coreCommands.js';
import 'monaco-editor/editor/contrib/find/browser/findController.js';
import 'monaco-editor/editor/contrib/gotoError/browser/gotoError.js';
import 'monaco-editor/editor/contrib/codeAction/browser/codeActionContributions.js';
import 'monaco-editor/editor/contrib/hover/browser/hoverContribution.js';
import 'monaco-editor/editor/contrib/suggest/browser/suggestController.js';
import 'monaco-editor/editor/contrib/snippet/browser/snippetController2.js';
import 'monaco-editor/editor/contrib/folding/browser/folding.js';
import 'monaco-editor/editor/contrib/bracketMatching/browser/bracketMatching.js';
import 'monaco-editor/editor/contrib/multicursor/browser/multicursor.js';
import 'monaco-editor/editor/contrib/contextmenu/browser/contextmenu.js';
import 'monaco-editor/editor/contrib/clipboard/browser/clipboard.js';
import 'monaco-editor/editor/contrib/comment/browser/comment.js';
import 'monaco-editor/editor/contrib/wordOperations/browser/wordOperations.js';
import 'monaco-editor/editor/contrib/tokenization/browser/tokenization.js';
import 'monaco-editor/editor/standalone/browser/quickAccess/standaloneCommandsQuickAccess.js';

self.MonacoEnvironment = { getWorker: () => new Worker('monaco-worker.js?v=' + window.TESL_BUILD.assets['monaco-worker.js'].sha256) };
monaco.languages.register({ id: 'tesl' });
monaco.languages.setLanguageConfiguration('tesl', {
  comments: { lineComment: '#' }, brackets: [['{', '}'], ['[', ']'], ['(', ')']],
  autoClosingPairs: [{ open: '{', close: '}' }, { open: '[', close: ']' }, { open: '(', close: ')' }, { open: '"', close: '"' }],
  wordPattern: /[A-Za-z_][A-Za-z0-9_.]*/g
});
monaco.languages.setMonarchTokensProvider('tesl', {
  keywords: ['module', 'exposing', 'import', 'fn', 'type', 'alias', 'record', 'entity', 'if', 'then', 'else', 'let', 'match', 'with', 'test', 'api', 'handler', 'server', 'requires'],
  proofs: ['fact', 'check', 'establish', 'ok', 'fail', 'auth', 'capture'],
  tokenizer: { root: [
    [/#.*$/, 'comment'], [/"(?:[^"\\]|\\.)*"/, 'string'], [/[0-9]+(?:\.[0-9]+)?/, 'number'],
    [/[A-Z][\w.]*/, 'type.identifier'], [/[a-z_][\w.]*/, { cases: { '@keywords': 'keyword', '@proofs': 'keyword', '@default': 'identifier' } }],
    [/:::|->|=>|[=+*/<>!&|:-]+/, 'operator']
  ] }
});

window.TeslMonaco = {
  mount(host, initial, callbacks) {
    let current = initial, projecting = false, composing = false;
    const model = monaco.editor.createModel(initial.source, 'tesl');
    const editor = monaco.editor.create(host, { model, automaticLayout: true, minimap: { enabled: false },
      fontSize: 14, scrollBeyondLastLine: false, tabSize: 2, wordWrap: 'off', fixedOverflowWidgets: true,
      ariaLabel: 'Tesl IDE editor', quickSuggestions: false });
    const highlight = editor.createDecorationsCollection();
    const disposables = [];
    const theme = () => {
      const mode = document.documentElement.dataset.theme;
      monaco.editor.setTheme(mode === 'dark' || (!mode && matchMedia('(prefers-color-scheme: dark)').matches) ? 'vs-dark' : 'vs');
    };
    const observer = new MutationObserver(theme); observer.observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme'] });
    const media = matchMedia('(prefers-color-scheme: dark)'); media.addEventListener('change', theme); theme();
    const span = diagnostic => ({ startLineNumber: diagnostic.start.line + 1, startColumn: diagnostic.start.col + 1,
      endLineNumber: diagnostic.end.line + 1, endColumn: diagnostic.end.col + 1 });
    const update = state => {
      current = state;
      if (model.getValue() !== state.source) {
        projecting = true;
        editor.pushUndoStop();
        editor.executeEdits('tesl-fix-or-example', [{ range: model.getFullModelRange(), text: state.source }]);
        editor.pushUndoStop(); projecting = false;
      }
      monaco.editor.setModelMarkers(model, 'tesl', state.diagnostics.map(d => ({ ...span(d),
        severity: d.severity === 'error' ? monaco.MarkerSeverity.Error : d.severity === 'warning' ? monaco.MarkerSeverity.Warning : monaco.MarkerSeverity.Info,
        message: d.message, code: d.code, source: d.source })));
      highlight.set(state.highlight ? [{ range: new monaco.Range(state.highlight.from, 1, state.highlight.to, 1),
        options: { isWholeLine: true, className: 'tesl-highlight', linesDecorationsClassName: 'tesl-highlight-gutter' } }] : []);
    };
    disposables.push(editor.onDidChangeModelContent(() => { if (!projecting) callbacks.edit(model.getValue(), composing); }));
    disposables.push(editor.onDidCompositionStart(() => { composing = true; callbacks.edit(model.getValue(), true); }));
    disposables.push(editor.onDidCompositionEnd(() => { composing = false; callbacks.edit(model.getValue(), false); }));
    disposables.push(editor.addAction({ id: 'tesl-learn', label: 'Tesl: Explain this', contextMenuGroupId: 'navigation', run: callbacks.learn }));
    disposables.push(editor.addAction({ id: 'tesl-check', label: 'Tesl: Check', keybindings: [monaco.KeyMod.CtrlCmd | monaco.KeyCode.Enter], run: callbacks.check }));
    disposables.push(editor.addAction({ id: 'tesl-search', label: 'Tesl: Find a builtin', keybindings: [monaco.KeyMod.CtrlCmd | monaco.KeyCode.KeyK], run: callbacks.search }));
    disposables.push(editor.addAction({ id: 'tesl-highlight', label: 'Tesl: Highlight selected lines', keybindings: [monaco.KeyMod.CtrlCmd | monaco.KeyMod.Shift | monaco.KeyCode.KeyH], run: () => {
      const s = editor.getSelection(); callbacks.highlight(s.isEmpty() ? null : { from: s.startLineNumber, to: s.endLineNumber - (s.endColumn === 1 && s.endLineNumber > s.startLineNumber ? 1 : 0) });
    } }));
    const fixCommand = editor.addCommand(0, (_, fix, source) => { if (model.getValue() === source) callbacks.fix(fix); });
    disposables.push(monaco.languages.registerCodeActionProvider('tesl', {
      providedCodeActionKinds: ['quickfix'],
      provideCodeActions(candidate, range) {
        if (candidate !== model || current.source !== model.getValue()) return { actions: [], dispose() {} };
        return { actions: current.diagnostics.filter(d => d.fix && d.start.line + 1 <= range.endLineNumber && d.end.line + 1 >= range.startLineNumber)
          .map(d => ({ title: d.fix.title, kind: 'quickfix', isPreferred: true,
            command: { id: fixCommand, title: d.fix.title, arguments: [d.fix, model.getValue()] } })), dispose() {} };
      }
    }));
    // Catalog discovery only, not inferred scope-aware IntelliSense. Import recipes
    // are shown in docs; inserting a name does not silently add imports or proofs.
    disposables.push(monaco.languages.registerCompletionItemProvider('tesl', {
      triggerCharacters: ['.'],
      async provideCompletionItems(candidate, position, _, token) {
        if (candidate !== model) return { suggestions: [] };
        const word = model.getWordUntilPosition(position), version = model.getVersionId();
        if (!word.word) return { suggestions: [] };
        const result = await callbacks.lookup(word.word);
        if (token.isCancellationRequested || model.isDisposed() || model.getVersionId() !== version) return { suggestions: [] };
        return { suggestions: result.results.map(entry => ({ label: entry.name, kind: monaco.languages.CompletionItemKind.Function,
          detail: entry.signature, documentation: { value: entry.doc + '\n\n' + (entry.import || '') + '\n\nProof and capability requirements still apply.', isTrusted: false },
          insertText: entry.name, range: new monaco.Range(position.lineNumber, word.startColumn, position.lineNumber, word.endColumn) })) };
      }
    }));
    disposables.push(monaco.languages.registerHoverProvider('tesl', {
      async provideHover(candidate, position, token) {
        if (candidate !== model) return null;
        const word = model.getWordAtPosition(position), version = model.getVersionId();
        if (!word) return null;
        const result = await callbacks.lookup(word.word);
        if (token.isCancellationRequested || model.isDisposed() || model.getVersionId() !== version) return null;
        const entry = result.results.find(e => e.name === word.word);
        return entry ? { contents: [{ value: '```tesl\n' + entry.signature + '\n```', isTrusted: false },
          { value: entry.doc + '\n\nProof and capability requirements still apply.', isTrusted: false }] } : null;
      }
    }));
    update(initial);
    return {
      editor, model, update,
      selection: () => { const s = editor.getSelection(); return { start: model.getOffsetAt(s.getStartPosition()), end: model.getOffsetAt(s.getEndPosition()) }; },
      select: (start, end) => { const a = model.getPositionAt(start), b = model.getPositionAt(end); editor.setSelection(new monaco.Range(a.lineNumber, a.column, b.lineNumber, b.column)); },
      jump: range => { const r = new monaco.Range(range.start.line + 1, range.start.col + 1, range.end.line + 1, range.end.col + 1); editor.setSelection(r); editor.revealRangeInCenter(r); editor.focus(); },
      dispose: () => { observer.disconnect(); media.removeEventListener('change', theme); disposables.forEach(d => d.dispose()); highlight.clear(); editor.dispose(); model.dispose(); }
    };
  }
};
