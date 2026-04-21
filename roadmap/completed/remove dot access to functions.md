when working with strings or other objects no functions should be magically connected to that object
if 3 <= title.length && title.length <= 120 then
should be
if 3 <= String.length title && String.length title <= 120 then
where String is an imported module