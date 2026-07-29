; Indent query — see vendor/tree-sitter-zig/indents.scm for the subset zedit
; evaluates.
[
  (compound_statement)
  (field_declaration_list)
  (enumerator_list)
  (initializer_list)
] @indent.begin

; `case 1:` opens its body on the next line with no token to close it.
((case_statement) @indent.begin
  (#set! indent.immediate))
