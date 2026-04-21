compile-examples.sh currently takes quite a lot of time. The actual compilation is really fast but to run the tesl tests and the racket tests takes a good while.

I think it has to do with either racket boot time or the postgres boot. Both should be fixable. This item should not change the output from the compiler or the acutal runtime performance - just tooling improvements so the feedbackloop is much faster.

A reasonable goal is that a whole compile-examples.sh  run takes less than 20 seconds. Preferrably a lot less than that.

The compile-examples.sh should also stream results to the console back continuously if possible, that way the run can be aborted by the user with more information.