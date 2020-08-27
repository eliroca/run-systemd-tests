#!/bin/sh

#set -x

if [ "$1" == "--help" ]; then
    echo "Running testsuite preparation:"
    echo "Usage: ./run-tests.sh --prepare"
    echo " "
    echo "Running binary tests:"
    echo "Usage: ./run-tests.sh [--skip=\$tests]"
    echo "                    \$tests is a space separated list of test names"
    echo "Running an extended test:"
    echo "Usage: ./run-tests.sh TEST-XX-NAME --\$option"
    echo " "
    echo "Options:"
    echo "--clean              cleanup before test"
    echo "--setup              prepare test"
    echo "--run                run test"
    echo "--clean-again        cleanup after test"
    echo "--all                clean, setup, run, clean-again for given test"
    exit 0
fi

[ -d logs ] || mkdir logs
export TEST_BASE_DIR='/var/opt/systemd-tests/test'

function binary_tests_summary {
    ws='[   ]'
    results=$(echo logs/*.trs)
    [[ -n "$results" ]] || results=/dev/null
    all=`grep "^$ws*:test-result:" $results | wc -l`
    pass=`grep "^$ws*:test-result:$ws*PASS" $results | wc -l`
    fail=`grep "^$ws*:test-result:$ws*FAIL" $results | wc -l`
    skip=`grep "^$ws*:test-result:$ws*SKIP" $results | wc -l`
    xfail=`grep "^$ws*:test-result:$ws*XFAIL" $results | wc -l`
    xpass=`grep "^$ws*:test-result:$ws*XPASS" $results | wc -l`
    error=`grep "^$ws*:test-result:$ws*ERROR" $results | wc -l`
    if [ $(expr $fail + $xpass + $error) -eq 0 ]; then
        success=0;
    else
        success=1;\
    fi

    echo "============================================================"
    echo "Binary tests summary for systemd $VERSION"
    echo "============================================================"
    echo -e "# TOTAL: $all"
    echo -e '\033[0;32m'"# PASS:  $pass"
    echo -e '\033[1;34m'"# SKIP:  $skip"
    #echo -e '\033[m'"# XFAIL: $xfail"
    echo -e '\033[0;31m'"# FAIL:  $fail"
    #echo -e '\033[m'"# XPASS: $xpass"
    echo -e '\033[m'"# ERROR: $error"
    echo "============================================================"
    echo -e "See logs/\$testname.log\n"
    exit $success
}

function cleanup {
    for id in 1 2 3; do
        [[ $(getent group systemdtestsuitegroup$id) ]] && groupdel systemdtestsuitegroup$id || :
    done
    [[ $(getent group adm) ]] && groupdel adm || :
    # TODO: find out where exactly this part is needed and write short explanation here
    # for user in systemd-journal-upload systemd-journal-remote; do
    #     [[ $(getent passwd $user) ]] && userdel $user
    # done
    # for group in systemd-journal-upload systemd-journal-remote mail; do
    #     [[ $(getent group $group) ]] && groupdel $group
    # done
}

function testsuite_prepare {
    VERSION=$(rpm -q systemd | sed -n 's/systemd-\([[:digit:]]*\).*/\1/p')
    echo "Preparing tests for version $VERSION"
    echo -e "\nChecking required packages\n"

    case "$VERSION" in
        234|243|244|245|246)
            ARCH=$(uname -m)
            case $ARCH in
                x86_64|i*86)
                     QEMU_PKG=qemu-x86
                     ;;
                ppc64*)
                     QEMU_PKG="qemu-ppc qemu-vgabios"
                     ;;
                s390x)
                     QEMU_PKG=qemu-s390
                     ;;
                aarch64)
                     QEMU_PKG=qemu-arm
                     ;;
            esac
            progs="lz4 busybox dhcp-client python3 plymouth yast2-firstboot binutils netcat-openbsd cryptsetup less socat $QEMU_PKG"
            [[ $VERSION == 237 ]] && progs+=" ninja quota ppp"
            [[ $VERSION == 246 ]] && progs+=" libcap-progs systemd-journal-remote"
            for prog in $progs; do
                rpm -q $prog || zypper -n in --no-recommends "$prog"
                [[ $? -ne 0 ]] && { echo "error installing required packages"; exit 1; }
            done
            # some testcases in test-execute rely on existence of user groups with certain gids
            # https://github.com/openSUSE/systemd/commit/ff5499824f96a7e7b93ca0b294eec62ad21e6592
            for id in 1 2 3; do
                groupadd -f -g $id systemdtestsuitegroup$id || :
            done
            # needed in TEST-12-ISSUE-3171
            [[ $(getent group adm) ]] || groupadd adm
            # TODO: find out where exactly this part is needed and write short explanation here
            # for user in systemd-journal-upload systemd-journal-remote; do
            #     [[ $(getent passwd $user) ]] || useradd $user
            # done
            # for group in systemd-journal-upload systemd-journal-remote mail; do
            #     [[ $(getent group $group) ]] || groupadd $group
            # done
            [[ -d /var/opt/systemd-tests/test/sys ]] || /var/opt/systemd-tests/test/sys-script.py /var/opt/systemd-tests/test
            ;;
        228)
            zypper -n in python3-lxml || zypper in python3-lxml
            ;;
        210)
            ;;
        *)
            echo "unknown systemd version: $VERSION"
            exit 1
            ;;
    esac

    #export testdata directory
    export SYSTEMD_TEST_DATA=/var/opt/systemd-tests/test

    #add grub timeout to bootloader and make the reboot verbose
    TIMEOUTSET=$(sed -n 's/GRUB_TIMEOUT=\(.*\)/\1/p' /etc/default/grub)
    if [ "$TIMEOUTSET" != "5" ]; then
        sed -i 's/GRUB_TIMEOUT=.*/GRUB_TIMEOUT=5/' /etc/default/grub
        grub2-mkconfig -o /boot/grub2/grub.cfg || return 1
    fi
    #create input files for test-catalog
    [[ -d /var/opt/systemd-tests/catalog ]] || ln -s /usr/lib/systemd/catalog /var/opt/systemd-tests/
    # only for tests running qemu
    # for i in $(ls /var/opt/systemd-tests/catalog/systemd.*.in); do mv $i ${i%%.in}; done
}

function run_binary_tests {
    testsuite_prepare

    testlist=$(echo test-*)" "
    testlist+="test/udev-test.pl test/hwdb-test.sh test/rule-syntax-check.py hwdb.d/parse_hwdb.py test/sysv-generator-test.py"

    skiplist="test-coredump-vacuum test-qcow2 test-patch-uid test-ns test-hostname test-ask-password-api test-dissect-image test-ipcrm test-btrfs test-netlink-manual test-cgroup test-install test-udev test-nss test-bus-benchmark test-ipv4ll-manual test-acd test-inhibit "
    skiplist+="*.sh test-driver "

    for testtoskip in $@; do
        for test in $testlist; do
            if [[ "$testtoskip" == "$test" ]]; then
                skiplist+=" $testtoskip"
                foundtesttoskip=true
                break
            fi
        done
        if [[ -z "$foundtesttoskip" ]]; then
            echo "test to skip not found: $testtoskip"
        fi
    done

    echo -e "\nRunning binary tests"
    echo -e "============================================================\n"

    [[ -f /proc/sys/kernel/nmi_watchdog ]] && WD=$(cat /proc/sys/kernel/nmi_watchdog)
    [[ "$WD" == 1 ]] && echo 0 > /proc/sys/kernel/nmi_watchdog

    for test in $testlist; do
        for skip in $skiplist; do
            [[ $test == $skip ]] && continue 2;
        done
        testname=$test
        if [[ "$test" == "test/rule-syntax-check.py" ]]; then
            testname="rule-syntax-check.sh"
            cat > $testname << EOF
#!/bin/sh

RULES=\$(find /var/opt/systemd-tests/rules.d -name *.rules)
RULES+=" "\$(find /var/opt/systemd-tests/rules.d -name *.rules.in)

./test/rule-syntax-check.py \$RULES
EOF
        chmod +x $testname
        fi
        ./test-driver --test-name $testname --log-file logs/${test#*/}.log --trs-file logs/${test#*/}.trs --color-tests yes
    done
    cleanup
}

function check_extended_test {
    testname=$(basename $dir)
    TESTDIR=$(sed -n '/systemd-test.*system.journal/s/.*\(systemd-test.[[:alnum:]]*\)\/.*/\1/p' ${TEST_BASE_DIR%%/test}/logs/$testname-run.log)
    TESTRES=$(grep "$testname RUN: .* \[OK\]" ${TEST_BASE_DIR%%/test}/logs/$testname-run.log)
    if [[ -n $TESTRES ]]; then
        TESTRES='\033[0;32m'"PASS"
    else
        TESTRES='\033[0;31m'"FAIL"
    fi
    echo -e "\n$TESTRES:" '\033[m'"$testname"
    echo ":test-result: ${TESTRES##*m}" > ${TEST_BASE_DIR%%/test}/logs/$testname.trs
    [[ "$TESTRES" =~ "PASS" ]] && [[ -n "$TESTDIR" ]] && rm -rf /var/tmp/$TESTDIR &>/dev/null
    # only needed for qemu
    # losetup -d
}

function run_extended_test {
    if [ $2 == "--setup" ]; then
        testsuite_prepare
    fi
    dir="$TEST_BASE_DIR/$1"
    cd "$dir"
    # if [ $1 == "TEST-16-EXTEND-TIMEOUT" ]; then
    #     sed -i '/SKIP_INITRD=yes/d' test.sh
    # fi
    echo -e "\nRunning extended test: $1 $2"
    echo -e "============================================================\n"
    ./test.sh $2 2>&1>> ${TEST_BASE_DIR%%/test}/logs/$1-${2#--}.log
    if [ "$2" == "--run" ]; then
        check_extended_test
    elif [[ "$2" == "--clean" ]]; then
        cleanup
    fi
}

test_options=(--clean --setup --run --clean-again)

if [[ -z "$1" || $1 =~ "--skip" ]]; then
    run_binary_tests ${@##--skip=}
    binary_tests_summary

elif [[ $1 =~ "--prepare" ]]; then
    testsuite_prepare

elif [[ -n "$1" && "$2" == "--all" ]]; then
    for opt in "${test_options[@]}"; do
        run_extended_test $1 $opt
    done

elif [[ -n "$1" && -n "$2" ]]; then
    for opt in "${test_options[@]}"; do
        if [[ "$opt" == "$2" ]]; then
            run_extended_test $1 $2
            exit 0
        fi
    done
    echo -e "Invalid option: $2\nsee './run-tests.sh --help'"
    exit 1

else
    echo "Invalid/missing parameters, see './run-tests.sh --help'"
    exit 1
fi
