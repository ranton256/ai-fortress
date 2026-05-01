// Test helper kept in a non-test file so it compiles even if the test
// file's tooling probes are run in some odd ordering. The binary
// itself doesn't reference these.

package main

import "os"

func osWriteFile(path string, data []byte, perm os.FileMode) error {
	return os.WriteFile(path, data, perm)
}
