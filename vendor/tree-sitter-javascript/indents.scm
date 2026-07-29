; Indent query — see vendor/tree-sitter-zig/indents.scm for the subset zedit
; evaluates.
[
  (statement_block)
  (class_body)
  (switch_body)
  (object)
  (object_pattern)
  (array)
] @indent.begin

([
  (switch_case)
  (switch_default)
] @indent.begin
  (#set! indent.immediate))
