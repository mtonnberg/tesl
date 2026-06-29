## Background

We have capability checks at compile time but we also have a runtime safety net (for most things, not for combined capabilities for higher order functions)

## Goal

Remove the runtime cost/safety net in Racket - our compiler should be enought (given that the compile checks is correct and roboust).