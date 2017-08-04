// tag::test[]
package examples

// end::test[]
import (
	"fmt"
	"net/http"         // <1>
	_ "net/http/pprof" // <2>
	"time"
	// tag::test[]
	"testing"
	// end::test[]
)

// tag::test[]
func TestNetHttpPProf(t *testing.T) {
	// end::test[]
	// tag::main[]
	// In a goroutine listener somewhere downstream of main() <3>
	var pprofErr error
	go func() { // <4>
		// Listen on port 6060 for `localhost`.  This could be [::] or `127.0.0.1`
		pprofErr = http.ListenAndServe("localhost:6060", nil) // <5>
	}()

	// Sleep for 1s to give the backend a chance to fail.
	time.Sleep(1 * time.Second) // <6>
	if pprofErr != nil {
		return fmt.Errorf("pprof endpoint failed to initialize: %v", pprofErr)
	}
	// end::main[]
	// tag::test[]
}

// end::test[]
