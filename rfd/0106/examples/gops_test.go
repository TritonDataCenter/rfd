// tag::test[]
package examples

// end::test[]
import (
	// tag::test[]
	"log"
	"testing"
	// end::test[]
	"github.com/google/gops/agent" // <1>
)

// tag::test[]
func TestAgent(t *testing.T) {
	// end::test[]
	// Somewhere after configuration, start the agent listener.  Exit if the agent
	// is unable to listen.
	if err := agent.Listen(nil); err != nil { // <2>
		log.Fatal(err)
	}
	// tag::test[]
}

// end::test[]
