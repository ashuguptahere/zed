; Indent query — see vendor/tree-sitter-zig/indents.scm for the subset zedit
; evaluates.
[
  (block)
  (field_declaration_list)
  (interface_type)
  (literal_value)
  (import_spec_list)
] @indent.begin

; `case x:` / `default:` open their body on the next line with no token to
; close it.
([
  (expression_case)
  (type_case)
  (communication_case)
  (default_case)
] @indent.begin
  (#set! indent.immediate))
