; Injections for the HTML grammar.
;
; Written for zedit's documented subset rather than copied from
; nvim-treesitter, whose rules live in its `html_tags` inheritance layer and
; lean on `#not-lua-match?` guards (only needed so vue/svelte can inherit them)
; and on css/regex/comment grammars zedit does not vendor.
;
; A <style> body would inject css; that grammar is not vendored, so style
; bodies keep the HTML layer's own styling.
(script_element
  (raw_text) @injection.content
  (#set! injection.language "javascript"))
