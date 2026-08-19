package teslrt

import "time"

// StartWorkers activates a queue's workers: `concurrency` goroutines, each claiming and running
// one job at a time. `dead` selects the dead-letter worker instead of the ordinary one.
func StartWorkers(queue *Queue, handler func(any) JobOutcome, concurrency int, dead bool) struct{} {
	return startWorkers(queue, handler, concurrency, dead, nil)
}

func startWorkers(queue *Queue, handler func(any) JobOutcome, concurrency int, dead bool, activity func(bool)) struct{} {
	if concurrency < 1 {
		concurrency = 1
	}
	for range concurrency {
		go func() {
			for {
				if activity != nil {
					activity(true)
				}
				outcome := JobOutcome{}
				if dead {
					outcome = ProcessNextDeadJob(queue, handler)
				} else {
					outcome = ProcessNextJob(queue, handler)
				}
				if !outcome.Ran {
					time.Sleep(50 * time.Millisecond)
				}
				if activity != nil {
					activity(false)
				}
			}
		}()
	}
	return struct{}{}
}
