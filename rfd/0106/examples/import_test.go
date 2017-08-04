// tag::test[]
package examples

// end::test[]
import (
	"database/sql" // <1>
	"fmt"
	// tag::test[]
	"testing"
	// end::test[]

	_ "github.com/lib/pq" // <2>
)

// tag::test[]

func Test_ImportSideEffects(t *testing.T) {
	const expectedDriverName = "postgres"

	var found bool
	for _, driver := range sql.Drivers() {
		if driver == expectedDriverName {
			found = true
			break
		}
	}

	if !found {
		t.Fatal(fmt.Sprintf("did not find driver %s", expectedDriverName))
	}
}

// end::test[]
