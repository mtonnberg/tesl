right now the capture function looks like this:
capture todoIdCapture: String::: TodoId todoId using string check isTodoId

and json codecs in general looks like this
codec NewTodo {
  toJson_forbidden
  fromJson [
    {
      title <- "title" with_codec stringCodec via isSafeTitle via lengthLessThan30 via containsAnA
    }
  ]
}

## Goal
* Streamline the syntax by updating the syntax of "capture" to
  ```
  capture todoIdCapture: String::: TodoId todoId using stringCodec via isTodoId
  ```
    * changed "string" to stringCodec, reducing the number of functions
    * using via instead of "check" reducing the overload use of "check" and make the syntax the same for both codecs and the capture statement
  
## Stretch-goals
If possible I think it would be clearer if the syntax updated from
```
codec NewTodo {
  toJson_forbidden
  fromJson [
    {
      title <- "title" with_codec stringCodec via isSafeTitle via lengthLessThan30 via containsAnA
    }
  ]
}
# and
capture todoIdCapture: String::: TodoId todoId && LengthLessThan30 todoId using stringCodec via isTodoId via lengthLessThan30
```
to
```
codec NewTodo {
  toJson_forbidden
  fromJson [
    {
      title <- "title" with_codec stringCodec via (isSafeTitle && lengthLessThan30 && containsAnA)
    }
  ]
}
# and
capture todoIdCapture: String::: TodoId todoId && LengthLessThan30 todoId using stringCodec via (isTodoId && lengthLessThan30)
```

If possible, update the formatter so, if the line is long, we have a predictable way of handling linebreaks, with one check-function per line for example
```
codec NewTodo {
  toJson_forbidden
  fromJson [
    {
      title <- "title"
                 with_codec stringCodec 
                 via
                    (  isSafeTitle
                    && lengthLessThan30
                    && containsAnA
                    )
    }
  ]
}
# and
capture todoIdCapture: String::: TodoId todoId
                              && LengthLessThan30 todoId
                         using stringCodec
                         via (  isTodoId
                             && lengthLessThan30
                             )
```

## Backward compability
After the changes, no other way of writing the capture/codec should be possible/compilable, to only have 1 way of doing something is very important