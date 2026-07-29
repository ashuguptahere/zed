; Indent query — see vendor/tree-sitter-zig/indents.scm for the subset zedit
; evaluates. Python has no closing token, so every opener is immediate: the
; node still ends on its own row while its body is being typed.
([
  (function_definition)
  (class_definition)
  (if_statement)
  (elif_clause)
  (else_clause)
  (for_statement)
  (while_statement)
  (with_statement)
  (try_statement)
  (except_clause)
  (finally_clause)
  (match_statement)
  (case_clause)
] @indent.begin
  (#set! indent.immediate))
