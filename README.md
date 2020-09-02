# run-systemd-tests
Script to run systemd's testsuite

```
 ./run-tests.sh --help

Running testsuite preparation:
Usage: ./run-tests.sh --prepare

Running binary tests:
Usage: ./run-tests.sh [--skip=$tests]
                    $tests is a space separated list of test names
Running an extended test:
Usage: ./run-tests.sh TEST-XX-NAME --$option

Options:
--clean              cleanup before test
--setup              prepare test
--run                run test
--clean-again        cleanup after test
--all                clean, setup, run, clean-again for given test
```
