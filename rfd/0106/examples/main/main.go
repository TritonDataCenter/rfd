package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"time"
)

func main() {
	os.Exit(realMain())
}

func realMain() int {
	var exitCode int

	ctxt := context.Background() // <1>

	// Trap SIGINT and call cancel on the context
	ctxt, cancel := context.WithCancel(ctxt) // <2>
	sigCh := make(chan os.Signal, 1)         // <3>
	signal.Notify(sigCh, os.Interrupt)       // <4>

	// Cancel any pending operations on exit of main()
	defer func() { // <5>
		signal.Stop(sigCh) // <6>
		cancel()           // <7>
	}()

	go func() { // <8>
		select {
		case sig := <-sigCh: // <9>
			switch sig { // <10>
			case os.Interrupt: // <11>
				fmt.Println("interrupt received")
				cancel()
				exitCode = 1
			default:
				panic(fmt.Sprintf("unsupported signal: %v", sig))
			}
		case <-ctxt.Done(): // <11>
		}
	}()

	const defaultNap = 5 * time.Second
	if err := powerNap(ctxt, defaultNap); err != nil {
		fmt.Printf("power nap error: %v\n", err)
	}

	return exitCode
}

// powerNap sleeps for time.Duration or returns early if the context is
// cancelled.
func powerNap(ctxt context.Context, d time.Duration) error {
	fmt.Printf("About to power nap for %s\n", d)
	select {
	case <-time.After(d):
		// time.After is used for example purposes only.  To apply a timeout to a
		// context use context.WithTimeout().
		fmt.Printf("Finished %s power nap\n", d)
	case <-ctxt.Done(): // <12>
		// Cancellation is not an error
		fmt.Printf("context done: %v\n", ctxt.Err())
	}

	return nil
}
