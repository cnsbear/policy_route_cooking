#!/bin/bash

#
# Created by Marko VPC GROUP on 2019-01-23.
# Copyright (c) 2019 Tencent . All rights reserved.
#

# safe option
set -euf -o pipefail

# debug option
# When this script is released, this option should be closed.
# set -x

NET_PATH="/sys/class/net"
ROUTE_TABLE_PATH="/etc/iproute2/rt_tables"

#NET_INTERFACES=""
UNUSED_INTERFACE="eth0 lo"

# System default route table-> 253:default 254:main 255:local,
# so the base table id should be great then 256.
ROUTE_TABLE_ID_BASE=256

function is_root {
    if [[ $EUID -ne 0 ]]; then
       echo "This script must be run as root"
       exit 1
    fi
}

function all_path_is_existed {
    if [[ ! -d ${NET_PATH} ]]; then
        echo "${NET_PATH} not exit"
        exit 1
    fi

    if [[ ! -f ${ROUTE_TABLE_PATH} ]]; then
        echo "${ROUTE_TABLE_PATH} not exit"
        exit 1
    fi
}

function network_interface_list {
    local ret="None"
    ret=$(ls -A ${NET_PATH})
    echo ${ret}
}

function network_interface_num {
    local ret="None"
    ret=$(ls -A ${NET_PATH} | wc -l)
    echo ${ret}
}

function calculate_table_id {
    local interface_num=$1
    local table_id=$(expr ${ROUTE_TABLE_ID_BASE} + ${interface_num})
    echo "${table_id}"
}

function create_route_table {
    local interface_num=$1
    local interface_name=$2
    local table_id=$(expr ${ROUTE_TABLE_ID_BASE} + ${interface_num})
    grep "${table_id} ${interface_name}" ${ROUTE_TABLE_PATH} >& /dev/null \
    || echo "${table_id} ${interface_name}" >> ${ROUTE_TABLE_PATH}
    #echo "${interface_name}"
}

function create_route {
    local table_name=$1
    local prefer_dev=$2
    ip route flush table ${table_name}
    ip route add default dev ${prefer_dev} table ${table_name}
}

function create_rule {
    local table_name=$1
    local prefer_src=$2
    ip rule list | grep "from ${prefer_src} lookup ${table_name}" >& /dev/null \
    || ip rule add from ${prefer_src}/32 table ${table_name}
}

# A interface may have many different in in different subnet.
function absorb_interface_ip {
    local ni_name=$1
    local ip_list=""
    ip_list=$(ip -4 addr list dev ${ni_name} | awk 'NR>1{print $2}' | awk -F/ '{if ($1 != "forever") print $1}')
    echo ${ip_list}
}

# eth0 and lo don't need the policy route, so they should be filter out.
function filter_out_unused_ni {
    local ni_list=$(network_interface_list)
    #NET_INTERFACES=$(network_interface_num)
    local new_list=""

    for e in ${ni_list}
    do
        if [[ ! ${UNUSED_INTERFACE[*]} =~ ${e} ]]; then
            new_list="${new_list} ${e}"
            #NET_INTERFACES=$(expr ${NET_INTERFACES} - 1)
        fi
    done
    echo ${new_list}
}

function configure_rule_for_each_sip {
    local table_name=$1
    local ip_list=$2
    for ip in ${ip_list}
    do
        create_rule ${table_name} ${ip}
    done
}

# I am sorry this core logic will be a little complicated. It
# will be simplified as more as possible and be commented more.
function cook {
    local table_name=0
    local ni_list=$(filter_out_unused_ni)
    local ni_counter=0
    local ip_list=""

    for ni in ${ni_list}
    do
        create_route_table ${ni_counter} ${ni}
        table_name=${ni}

        # ni_counter++
        ni_counter=$(expr ${ni_counter} + 1)

        create_route ${table_name} ${ni}
        ip_list=$(absorb_interface_ip ${ni})
        configure_rule_for_each_sip ${table_name} "${ip_list}"
    done
}

function show_rule {
    echo "Rules: "
    ip rule list
    echo ""
}

function show_table {
    local table_name=$1
    echo "Table ${table_name}: "
    grep "${table_name}" ${ROUTE_TABLE_PATH} >& /dev/null \
    && ip route list table ${table_name}
    echo ""
}

function flush_table {
    local table_name=$1
    grep "${table_name}" ${ROUTE_TABLE_PATH} >& /dev/null \
    && ip route flush table ${table_name}
}

function flush_rule {
    local table_name=$1
    local ip_list=$2
    for prefer_src in ${ip_list}
    do
	    ip rule list | grep "from ${prefer_src} lookup ${table_name}" >& /dev/null \
	    && ip rule delete from ${prefer_src}/32 table ${table_name}
    done
}

function enjoy_delicacy {
    local table_name=""
    local ni_list=$(filter_out_unused_ni)

    show_rule

    for ni in ${ni_list}
    do
        table_name=${ni}
        show_table ${table_name}
    done
}

function do_the_dishes {
    # skip the -t option
    shift

    local table_name=""
    local ni_list=$@
    local ip_list=""

    for ni in ${ni_list}
    do
        table_name=${ni}
        flush_table ${table_name}

        ip_list=$(absorb_interface_ip ${ni})
        flush_rule ${table_name} "${ip_list}"
    done
}

function clean_leftovers {
    local table_name=""
    local ni_list=$(filter_out_unused_ni)
    local ip_list=""

    for ni in ${ni_list}
    do
        table_name=${ni}
        flush_table ${table_name}

        ip_list=$(absorb_interface_ip ${ni})
        flush_rule ${table_name} "${ip_list}"
    done

}

function cleanup_success {
    echo "Clean up done! Enjoy it."
}

function parse_option {
    if [[ $# -eq 0 ]]; then
        return  0
    fi

    while getopts "hcsC" OPTION; do
        case ${OPTION} in

            c)
                clean_leftovers && \
                cleanup_success
                exit 0
                ;;
            s)
                enjoy_delicacy
                exit 0
                ;;
            C)
                do_the_dishes $@
                exit 0
                ;;
            h)
                echo "Usage:"
                echo "$0 -h "
                echo "$0 -s "
                echo "$0 -c "
                echo "$0 -C "
                echo ""
                echo "   -c     clean the chaos that user make."
                echo "   -h     help (this output)."
                echo "   -s     show all policy routes."
                echo "   -C     [table list] specify table id to clean up."
                exit 0
                ;;
        esac
        done
}

function cook_success {
    echo "Cooking done! Enjoy it."
}

# All of the logic operation should be keep idempotent.
function main {
    parse_option $@ && \
    is_root && \
    all_path_is_existed && \
    cook && \
    cook_success
}

main $@

## Test Advice
# 1. more than 2 nic
# 2. more than one ip in a nic
# 3. should have logic card, include bond, vlan and so on.
# 4. should not have side effect, when exec this script more than one times.
# 5. should not have side effect, when no extra nic except eth0 and lo.
