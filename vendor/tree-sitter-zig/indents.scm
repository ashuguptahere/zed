; Indent query — zedit's subset: nodes captured @indent.begin indent the lines
; that follow the line they open on. `#set! indent.immediate` marks an opener
; that has no closing token on screen yet (a colon/`case` style block), so it
; still counts when it starts and ends on the same row.
[
  (block)
  (struct_declaration)
  (enum_declaration)
  (union_declaration)
  (opaque_declaration)
  (switch_expression)
  (initializer_list)
] @indent.begin
