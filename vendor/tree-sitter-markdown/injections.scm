; Injections for the markdown block grammar.
;
; Written for zedit's documented subset (@injection.content / @injection.language
; and the `#set! injection.language` directive) rather than copied from
; nvim-treesitter, whose file also injects html/yaml/toml and uses the
; `#offset!` / `injection.combined` / `injection.include-children` directives
; zedit does not implement. The two rules kept below are the two that matter,
; and are nvim's own text for them.

; A fenced block is parsed by whatever language its info string names, when
; that is one of the vendored grammars ("```python" -> the python grammar).
(fenced_code_block
  (info_string
    (language) @injection.language)
  (code_fence_content) @injection.content)

; Every inline span goes to the markdown-inline grammar — including a table
; cell, which the block grammar keeps out of `(inline)`. This is what used to
; be a hardcoded second layer over the whole document.
([
  (inline)
  (pipe_table_cell)
] @injection.content
  (#set! injection.language "markdown_inline"))
