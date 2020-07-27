#!/bin/sh

#set -x

if [ "$1" == "--help" ]; then
    echo "Running binary tests:"
    echo "Usage: ./run-tests.sh [--skip=\$tests]"
    echo "                    \$tests is a space separated list of test names"
    echo "Running an extended test:"
    echo "Usage: ./run-tests.sh TEST-XX-NAME --option"
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
    # TODO: find out where exactly this part is needed and write short explanation here
    # for id in 1 2 3; do
    #     [[ $(getent passwd systemdtestsuiteuser$id) ]] && userdel systemdtestsuiteuser$id
    #     [[ $(getent group systemdtestsuitegroup$id) ]] && groupdel systemdtestsuitegroup$id
    # done
    # for user in systemd-journal-upload systemd-journal-remote; do
    #     [[ $(getent passwd $user) ]] && userdel $user
    # done
    # for group in systemd-journal-upload systemd-journal-remote mail adm; do
    #     [[ $(getent group $group) ]] && groupdel $group
    # done
}

function testsuiteprepare {
    VERSION=$(rpm -q systemd | sed -n 's/systemd-\([[:digit:]]*\).*/\1/p')
    echo "Preparing tests for version $VERSION"
    echo -e "\nChecking required packages\n"

    case "$VERSION" in
        234|243|244|245)
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
            for prog in $progs; do
                rpm -q $prog || zypper -n in --no-recommends "$prog"
                [[ $? -ne 0 ]] && { echo "error installing required packages"; exit 1; }
            done
            for id in 1 2 3; do
                [[ $(getent group systemdtestsuitegroup$id) ]] || groupadd -g $id systemdtestsuitegroup$id
                [[ $(getent passwd systemdtestsuiteuser$id) ]] || useradd -u $id -g $id systemdtestsuiteuser$id
            done
            for user in systemd-journal-upload systemd-journal-remote; do
                [[ $(getent passwd $user) ]] || useradd $user
            done
            for group in systemd-journal-upload systemd-journal-remote mail adm; do
                [[ $(getent group $group) ]] || groupadd $group
            done
            [[ -d /var/opt/systemd-tests/test/sys ]] || /var/opt/systemd-tests/test/sys-script.py /var/opt/systemd-tests/test
            ;;
        228)
            zypper -n in python3-lxml || zypper in python3-lxml
            ;;
        210)
            ;;
        *)
            echo "unknown systemd version: $VERSION"
            cleanup
            exit 1
            ;;
    esac

    #export testdata directory
    export SYSTEMD_TEST_DATA=/var/opt/systemd-tests/test

    #create input files for test-catalog
    [[ -d /var/opt/systemd-tests/catalog ]] || ln -s /usr/lib/systemd/catalog /var/opt/systemd-tests/
    # only for tests running qemu
    # for i in $(ls /var/opt/systemd-tests/catalog/systemd.*.in); do mv $i ${i%%.in}; done
}


if [[ -z "$2" || "$2" == "--setup" ]]; then
    testsuiteprepare

    #add grub timeout to bootloader and make the rebote verbose
    TIMEOUTSET=$(sed -n 's/GRUB_TIMEOUT=\(.*\)/\1/p' /etc/default/grub)
    if [ "$TIMEOUTSET" != "5" ]; then
        sed -i 's/GRUB_TIMEOUT=.*/GRUB_TIMEOUT=5/' /etc/default/grub
        grub2-mkconfig -o /boot/grub2/grub.cfg || return 1
    fi
fi

if [ -z "$1" ]; then
    testfiles=$(echo test-*)" "
    testfiles+="test/udev-test.pl
    test/hwdb-test.sh
    test/rule-syntax-check.py
    hwdb.d/parse_hwdb.py
    test/sysv-generator-test.py"

    skiptests="test-coredump-vacuum test-qcow2 test-patch-uid test-ns test-hostname test-ask-password-api test-dissect-image test-ipcrm test-btrfs test-netlink-manual test-cgroup test-install test-udev test-nss test-bus-benchmark test-ipv4ll-manual test-acd test-inhibit "
    skiptests+="*.sh test-driver "

    for toskip in ${@##--skip=}; do
        [[ "$testfiles" =~ "$toskip" ]] && skiptests+=" $toskip"
    done

    echo -e "\nrunning basic tests\n"

    [[ -f /proc/sys/kernel/nmi_watchdog ]] && WD=$(cat /proc/sys/kernel/nmi_watchdog)
    [[ "$WD" == 1 ]] && echo 0 > /proc/sys/kernel/nmi_watchdog

    for test in $testfiles; do
        for skip in $skiptests; do
            [[ $skip == $test ]] && continue 2;
        done
        [[ "$test" == "test/rule-syntax-check.py" ]] && testname=rule-syntax-check-run.sh || testname=$test
        ./test-driver --test-name $testname --log-file logs/${test#*/}.log --trs-file logs/${test#*/}.trs --color-tests yes
    done

    summary
    cleanup
    exit $success
else
    #route package not available in openSUSE
    sed -i 's/route //' test/test-functions
    TESTDIR='none'
    if [ "$1" == "--all" ]; then
        echo -e "\nrunning all extended tests\n"
        for dir in $(echo test/TEST-*); do
            [[ "$dir" == "test/TEST-06-SELINUX" ]] && continue
            cd $dir
            sed -i '/SKIP_INITRD=yes/d' test.sh
            testname=$(basename $dir)
            ./test.sh --clean &> /dev/null
            ./test.sh --setup &> ${TEST_BASE_DIR%%/test}/logs/$testname-setup.log
            [[ $? == 0 ]] && ./test.sh --run &> ${TEST_BASE_DIR%%/test}/logs/$testname-run.log
        done
    else
        echo -e "\nRunning extended tests"
        echo -e "======================\n"
        dir="test/$1"
        cd "$dir"
        sed -i '/SKIP_INITRD=yes/d' test.sh
        testname=$(basename $dir)
        if [[ -n "$1" && -z "$2" ]]; then
            if [ "$1" == "TEST-01-BASIC" ]; then
                ./test.sh --clean &> /dev/null
                ./test.sh --setup &> ${TEST_BASE_DIR%%/test}/logs/$testname-setup.log
            fi
            ./test.sh --run &> ${TEST_BASE_DIR%%/test}/logs/$testname-run.log
        elif [[ -n "$1" && -n "$2" ]]; then
            echo -e "Running $1 $2\n"
            ./test.sh $2 2>&1>> ${TEST_BASE_DIR%%/test}/logs/$testname-${2#--}.log
        else
            echo "INVALID PARAMETERS"
            exit 1
        fi

        if [[ -z "$2" || "$2" == "--run" ]]; then
            TESTDIR=$(sed -n '/systemd-test.*system.journal/s/.*\(systemd-test.[[:alnum:]]*\)\/.*/\1/p' ${TEST_BASE_DIR%%/test}/logs/$testname-run.log)
            echo -e "\ntestresult:"
            for file in $(ls /failed* 2>/dev/null); do
                echo "$file: $(cat $file)"
            done
            for file in $(ls /testok* 2>/dev/null); do
                content=$(cat $file)
                RESULT+=$content
                echo "$file: $content"
            done
            if [[ "${RESULT:9:2}" == "OK" ]]; then
                TESTRES='\033[0;32m'"PASS"
            else
                TESTRES='\033[0;31m'"FAIL"
            fi
            echo -e "\n$TESTRES:" '\033[m'"$testname"
            echo ":test-result: ${TESTRES##*m}" > ${TEST_BASE_DIR%%/test}/logs/$testname.trs
            [[ "$TESTRES" =~ "PASS" ]] && [[ -n "$TESTDIR" ]] && rm -rf /var/tmp/$TESTDIR &>/dev/null
            cd ${TEST_BASE_DIR%%/test}
            # only needed for qemu
            # losetup -d
            cleanup
        fi

        if [[ -z "$2" ]]; then
            summary
        fi
    fi
fi

exit $success
