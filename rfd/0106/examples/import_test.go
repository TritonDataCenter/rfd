package examples

import (
	"database/sql" // <1>
	"fmt"
	"testing"

	_ "github.com/lib/pq" // <2>
)

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
